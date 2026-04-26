defmodule Rho.Sandbox do
  @moduledoc """
  Manages AgentFS-backed sandbox filesystems for sessions.

  Creates an overlay filesystem where the real workspace is the read-only base
  and all writes are captured in a SQLite database. Uses NFS mount on macOS
  and FUSE on Linux.
  """

  require Logger

  @sandbox_dir Path.expand("~/.rho/sandboxes")
  @mount_ready_timeout 10_000

  defstruct [:session_id, :db_path, :mount_path, :workspace, :port, :agent_id]

  @doc """
  Start a sandboxed overlay filesystem for the given session.

  Returns `{:ok, %Sandbox{}}` with `mount_path` pointing to the overlay mount,
  or `{:error, reason}` if setup fails.
  """
  def start(session_id, workspace) do
    with :ok <- Rho.Agent.Primary.validate_session_id(session_id) do
      do_start(session_id, workspace)
    end
  end

  defp do_start(session_id, workspace) do
    agent_id = sanitize_id(session_id)
    db_dir = db_dir(session_id)
    db_path = Path.join([db_dir, ".agentfs", "#{agent_id}.db"])
    mount_path = mount_path(session_id)

    File.mkdir_p!(db_dir)
    kill_stale_agentfs(agent_id, mount_path)
    clean_stale_mount(mount_path)
    clean_stale_db_locks(db_dir, agent_id)
    File.mkdir_p!(mount_path)

    workspace = Path.expand(workspace)

    with :ok <- init_db(agent_id, workspace, db_dir),
         {:ok, port} <- start_mount(agent_id, mount_path, db_dir),
         :ok <- wait_for_mount(mount_path) do
      sandbox = %__MODULE__{
        session_id: session_id,
        db_path: db_path,
        mount_path: mount_path,
        workspace: workspace,
        port: port,
        agent_id: agent_id
      }

      Logger.info("[Sandbox] Started for #{session_id} at #{mount_path}")
      {:ok, sandbox}
    else
      {:error, reason} ->
        # Clean up on failure
        File.rm_rf(mount_path)
        {:error, reason}
    end
  end

  @doc "Stop the sandbox, unmounting the filesystem."
  def stop(nil), do: :ok

  def stop(%__MODULE__{} = sandbox) do
    Logger.info("[Sandbox] Stopping for #{sandbox.session_id}")

    # Kill the agentfs process via port info to ensure DB lock is released
    if sandbox.port do
      try do
        case Port.info(sandbox.port, :os_pid) do
          {:os_pid, os_pid} ->
            System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)

          _ ->
            :ok
        end

        Port.close(sandbox.port)
      rescue
        _ -> :ok
      end

      # Wait briefly for process to exit before unmounting
      Process.sleep(200)
    end

    # Unmount
    case System.cmd("umount", [sandbox.mount_path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> Logger.warning("[Sandbox] umount warning: #{out}")
    end

    # Clean up mount directory
    File.rmdir(sandbox.mount_path)

    :ok
  end

  @doc """
  Show the diff of changes made in the sandbox vs the base workspace.

  Uses filesystem-level comparison (works while mounted, unlike `agentfs diff`
  which requires exclusive DB access).
  """
  def diff(%__MODULE__{} = sandbox) do
    case System.cmd("diff", ["-rq", sandbox.workspace, sandbox.mount_path],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> {:ok, "No changes"}
      {output, 1} -> {:ok, format_diff(output, sandbox)}
      {output, code} -> {:error, {:diff_failed, "diff failed (#{code}): #{output}"}}
    end
  end

  defp format_diff(raw_output, sandbox) do
    raw_output
    |> String.split("\n", trim: true)
    |> Enum.map_join("\n", fn line ->
      line
      |> String.replace(sandbox.workspace, "<workspace>")
      |> String.replace(sandbox.mount_path, "<sandbox>")
    end)
  end

  @doc """
  Commit sandbox changes to the real workspace by syncing from the overlay.

  Copies modified files from the mount to the real workspace.
  Must be called while the sandbox is still mounted.
  """
  def commit(%__MODULE__{} = sandbox) do
    case System.cmd(
           "rsync",
           [
             "-a",
             "--exclude",
             ".DS_Store",
             "--exclude",
             "._*",
             "#{sandbox.mount_path}/",
             "#{sandbox.workspace}/"
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:rsync_failed, "rsync failed (#{code}): #{output}"}}
    end
  end

  @doc "Returns the mount path for a session (whether or not it's active)."
  def mount_path(session_id) do
    :ok = Rho.Agent.Primary.validate_session_id(session_id)
    Path.join(System.tmp_dir!(), "rho-sandbox-#{session_id}")
  end

  # --- Private ---

  # Kill any agentfs processes still holding the DB lock for this agent/mount.
  defp kill_stale_agentfs(agent_id, mount_path) do
    # Sanitize agent_id to prevent pattern injection in pgrep
    safe_agent_id = String.replace(agent_id, ~r/[^a-zA-Z0-9_\-]/, "")

    case System.cmd("pgrep", ["-f", "agentfs mount.*#{safe_agent_id}"], stderr_to_stdout: true) do
      {output, 0} ->
        pids =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&Regex.match?(~r/^\d+$/, String.trim(&1)))

        Logger.info(
          "[Sandbox] Killing #{length(pids)} stale agentfs process(es) for #{safe_agent_id}"
        )

        for pid <- pids do
          System.cmd("kill", [pid], stderr_to_stdout: true)
        end

        # Also unmount since the process was holding it
        System.cmd("umount", [mount_path], stderr_to_stdout: true)
        # Brief wait for process to exit and release the DB lock
        Process.sleep(500)

      _ ->
        :ok
    end
  end

  # Remove stale SQLite WAL/SHM journal files that can hold locks after unclean shutdown.
  defp clean_stale_db_locks(db_dir, agent_id) do
    db_base = Path.join([db_dir, ".agentfs", "#{agent_id}.db"])

    for suffix <- ["-wal", "-shm"] do
      path = db_base <> suffix

      if File.exists?(path) do
        Logger.info("[Sandbox] Removing stale DB lock file: #{path}")
        File.rm(path)
      end
    end
  end

  # Remove stale mount point artifacts (e.g., a regular file left after an
  # unclean shutdown where the NFS/FUSE mount wasn't properly unmounted).
  defp clean_stale_mount(mount_path) do
    case File.stat(mount_path) do
      {:ok, %{type: :directory}} ->
        # Try unmounting in case it's a stale mount
        System.cmd("umount", [mount_path], stderr_to_stdout: true)
        :ok

      {:ok, _other_type} ->
        # Non-directory file at mount path — remove it
        Logger.warning("[Sandbox] Removing stale mount artifact at #{mount_path}")
        File.rm!(mount_path)

      {:error, _} ->
        :ok
    end
  end

  defp db_dir(session_id) do
    Path.join(@sandbox_dir, to_string(session_id))
  end

  defp sanitize_id(session_id) do
    session_id
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    |> then(&"rho_#{&1}")
  end

  defp init_db(agent_id, workspace, db_dir) do
    db_path = Path.join([db_dir, ".agentfs", "#{agent_id}.db"])

    if File.exists?(db_path) do
      :ok
    else
      case System.cmd("agentfs", ["init", "--base", workspace, agent_id],
             cd: db_dir,
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {output, code} -> {:error, "agentfs init failed (#{code}): #{output}"}
      end
    end
  end

  defp start_mount(agent_id, mount_path, db_dir) do
    agentfs = System.find_executable("agentfs")

    if agentfs do
      port =
        Port.open(
          {:spawn_executable, agentfs},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            cd: db_dir,
            args: ["mount", "-f", "--auto-unmount", agent_id, mount_path]
          ]
        )

      {:ok, port}
    else
      {:error, "agentfs binary not found in PATH"}
    end
  end

  defp wait_for_mount(mount_path) do
    deadline = System.monotonic_time(:millisecond) + @mount_ready_timeout
    do_wait_for_mount(mount_path, deadline)
  end

  defp do_wait_for_mount(mount_path, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, "mount timed out after #{@mount_ready_timeout}ms"}
    else
      case check_mount_ready(mount_path) do
        :ok -> :ok
        :not_ready -> Process.sleep(100) && do_wait_for_mount(mount_path, deadline)
      end
    end
  end

  defp check_mount_ready(mount_path) do
    case File.ls(mount_path) do
      {:ok, _files} ->
        {mounts, 0} = System.cmd("mount", [])
        if String.contains?(mounts, mount_path), do: :ok, else: :not_ready

      {:error, _} ->
        :not_ready
    end
  end
end
