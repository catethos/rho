defmodule Rho.Agent.Primary do
  @moduledoc """
  Thin helper for the "primary agent" convention — the single
  interlocutor agent whose `agent_id` is `"<session_id>/primary"`.

  A session is just a namespace (`session_id`). Its primary agent is
  the one a CLI, web UI, or API caller talks to by default. Other
  agents in the session are peers whose ids are
  `"<session_id>/primary/<name>"` — rooted under the primary to encode
  the parent relationship.

  This module centralises the hierarchical id convention and the
  EventLog-startup side-effect. Direct `Rho.Agent.Worker` /
  `Rho.Agent.Registry` calls remain the canonical API for peer-level
  operations.
  """

  alias Rho.Agent.Worker

  @doc """
  Validate a user-supplied session_id. Rejects ids containing path
  separators (`/`, `\\`), leading dots (which could escape the session
  directory when used as a filesystem path), or non-printable chars.

  Returns `:ok` or `{:error, reason}`.

  ## Examples

      iex> Rho.Agent.Primary.validate_session_id("my-session")
      :ok

      iex> Rho.Agent.Primary.validate_session_id("a/b")
      {:error, :invalid_session_id}

      iex> Rho.Agent.Primary.validate_session_id("../etc")
      {:error, :invalid_session_id}

      iex> Rho.Agent.Primary.validate_session_id("")
      {:error, :invalid_session_id}
  """
  @spec validate_session_id(term()) :: :ok | {:error, :invalid_session_id}
  def validate_session_id(sid) when is_binary(sid) and byte_size(sid) > 0 do
    cond do
      String.contains?(sid, ["/", "\\", "\0"]) -> {:error, :invalid_session_id}
      String.starts_with?(sid, ".") -> {:error, :invalid_session_id}
      true -> :ok
    end
  end

  def validate_session_id(_), do: {:error, :invalid_session_id}

  @doc "Build the agent_id of the primary agent for a session."
  @spec agent_id(String.t()) :: String.t()
  def agent_id(session_id), do: session_id <> "/primary"

  @doc """
  Build a peer agent_id nested under a session's primary agent:
  `"<session_id>/primary/<name>"`.
  """
  @spec peer_agent_id(String.t(), String.t()) :: String.t()
  def peer_agent_id(session_id, name), do: agent_id(session_id) <> "/" <> name

  @doc """
  Derive the parent agent_id from a hierarchical agent_id by stripping
  the final `/`-separated segment. Returns `nil` for primary agents
  (`"<sid>/primary"`) and for ids that do not follow the convention.

  ## Examples

      iex> Rho.Agent.Primary.parent_of("sess_1/primary/agent_42")
      "sess_1/primary"

      iex> Rho.Agent.Primary.parent_of("sess_1/primary/agent_42/agent_99")
      "sess_1/primary/agent_42"

      iex> Rho.Agent.Primary.parent_of("sess_1/primary")
      nil

      iex> Rho.Agent.Primary.parent_of("legacy_id")
      nil
  """
  @spec parent_of(String.t()) :: String.t() | nil
  def parent_of(agent_id) when is_binary(agent_id) do
    case String.split(agent_id, "/") do
      segments when length(segments) >= 3 ->
        segments |> Enum.drop(-1) |> Enum.join("/")

      _ ->
        nil
    end
  end

  @doc """
  Depth of an agent derived from its hierarchical agent_id. The
  primary (`"<sid>/primary"`) is depth 0; each extra `/`-segment adds
  one level. Legacy or opaque agent ids that don't follow the
  convention return 0.

  ## Examples

      iex> Rho.Agent.Primary.depth_of("sess_1/primary")
      0

      iex> Rho.Agent.Primary.depth_of("sess_1/primary/agent_42")
      1

      iex> Rho.Agent.Primary.depth_of("sess_1/primary/agent_42/agent_99")
      2

      iex> Rho.Agent.Primary.depth_of("legacy_id")
      0
  """
  @spec depth_of(String.t()) :: non_neg_integer()
  def depth_of(agent_id) when is_binary(agent_id) do
    case String.split(agent_id, "/") do
      [_sid, "primary" | rest] -> length(rest)
      _ -> 0
    end
  end

  @doc "Return the pid of the primary agent for `session_id`, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) do
    Worker.whereis(agent_id(session_id))
  end

  @doc """
  Find or start the primary agent for `session_id`. Also ensures the
  session EventLog GenServer is running. Returns `{:ok, pid}`.

  When `:user_id` is supplied, enforces session ownership via
  `Rho.SessionOwners` — a session can only be resumed by the user who
  first created it. Pass `nil` (or omit) for system contexts (CLI, mix
  tasks, internal background work).
  """
  @spec ensure_started(String.t(), keyword()) ::
          {:ok, pid()} | {:error, :invalid_session_id | :forbidden}
  def ensure_started(session_id, opts \\ []) do
    with :ok <- validate_session_id(session_id),
         :ok <- Rho.SessionOwners.authorize(session_id, opts[:user_id]) do
      do_ensure_started(session_id, opts)
    end
  end

  defp do_ensure_started(session_id, opts) do
    workspace = opts[:workspace] || default_workspace(opts[:user_id], session_id)
    File.mkdir_p!(workspace)
    result = find_or_start_worker(session_id, workspace, opts)

    case result do
      {:ok, _pid} ->
        ensure_event_log(session_id, workspace)
        result

      error ->
        error
    end
  end

  # When user_id is known, isolate per-user filesystem state under
  # `<data_dir>/users/u<id>/workspaces/<sid>`. Falls back to cwd for
  # CLI / mix tasks where there's no logged-in user.
  defp default_workspace(nil, _session_id), do: File.cwd!()
  defp default_workspace(user_id, session_id), do: Rho.Paths.user_workspace(user_id, session_id)

  defp find_or_start_worker(session_id, workspace, opts) do
    case whereis(session_id) do
      nil -> start_new_worker(session_id, workspace, opts)
      pid -> {:ok, pid}
    end
  end

  defp start_new_worker(session_id, workspace, opts) do
    worker_opts =
      [
        agent_id: agent_id(session_id),
        session_id: session_id,
        workspace: workspace,
        agent_name: opts[:agent_name] || :default,
        role: :primary,
        user_id: opts[:user_id],
        organization_id: opts[:organization_id]
      ]
      |> then(fn wo ->
        if opts[:tape_ref], do: Keyword.put(wo, :tape_ref, opts[:tape_ref]), else: wo
      end)
      |> then(fn wo ->
        if opts[:run_spec], do: Keyword.put(wo, :run_spec, opts[:run_spec]), else: wo
      end)

    case Rho.Agent.Supervisor.start_worker(worker_opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  List live primary agents as `Worker.info/1` maps, optionally
  filtered by session_id prefix.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    prefix = opts[:prefix] || ""

    prefix
    |> Rho.Agent.Registry.find_by_session_prefix()
    |> Enum.filter(&(&1.role == :primary and &1.pid != nil))
    |> Enum.map(fn entry ->
      try do
        Worker.info(entry.pid)
      catch
        :exit, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Resume a previously stopped session. Starts a fresh primary agent
  that picks up the existing tape context from disk. Equivalent to
  `ensure_started/2` — the tape store already persists entries to
  `~/.rho/tapes/`, so the new agent's first LLM call will include
  the full prior conversation.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec resume(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def resume(session_id, opts \\ []) do
    ensure_started(session_id, opts)
  end

  @doc """
  Stop every agent in a session and its EventLog. Idempotent.
  """
  @spec stop(String.t()) :: :ok
  def stop(session_id) do
    Rho.Agent.EventLog.stop(session_id)

    for agent <- Rho.Agent.Registry.list_all(session_id) do
      if pid = Worker.whereis(agent.agent_id) do
        GenServer.stop(pid, :shutdown, 5_000)
      end

      Rho.Agent.Registry.unregister(agent.agent_id)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  List sessions that can be resumed — have event logs on disk but no
  live primary agent. Returns `[%{session_id: String.t(), events_path: String.t(), modified_at: DateTime.t()}]`.
  """
  def list_resumable(opts \\ []) do
    workspace = opts[:workspace] || File.cwd!()
    sessions_dir = Path.join([workspace, "_rho", "sessions"])

    case File.ls(sessions_dir) do
      {:ok, dirs} ->
        live_sessions =
          Rho.Agent.Registry.find_by_session_prefix("")
          |> Enum.filter(&(&1.role == :primary and &1.pid != nil))
          |> MapSet.new(& &1.session_id)

        dirs
        |> Enum.filter(fn dir ->
          events_path = Path.join([sessions_dir, dir, "events.jsonl"])
          File.exists?(events_path) and dir not in live_sessions
        end)
        |> Enum.map(fn dir ->
          events_path = Path.join([sessions_dir, dir, "events.jsonl"])
          {:ok, stat} = File.stat(events_path)

          %{
            session_id: dir,
            events_path: events_path,
            modified_at: stat.mtime |> NaiveDateTime.from_erl!()
          }
        end)
        |> Enum.sort_by(& &1.modified_at, {:desc, NaiveDateTime})

      {:error, _} ->
        []
    end
  end

  @doc "Resolve a session id from keyword opts (channel/chat_id fallback)."
  @spec resolve_session_id(keyword()) :: String.t()
  def resolve_session_id(opts) do
    if opts[:session_id] do
      opts[:session_id]
    else
      channel = opts[:channel] || "cli"
      chat_id = opts[:chat_id] || "default"
      "#{channel}:#{chat_id}"
    end
  end

  @doc """
  Generate a fresh child agent id nested under a parent agent:
  `"<parent_agent_id>/agent_<unique>"`. The caller is responsible for
  passing the actual spawning agent's id so that the returned id
  encodes the full spawn hierarchy.
  """
  @spec new_agent_id(String.t()) :: String.t()
  def new_agent_id(parent_agent_id) do
    parent_agent_id <> "/agent_#{:erlang.unique_integer([:positive])}"
  end

  @doc """
  Generate a fresh opaque id suffix (not rooted to any session). Useful
  for minting session ids in external entry points.
  """
  @spec new_id() :: String.t()
  def new_id do
    "agent_#{:erlang.unique_integer([:positive])}"
  end

  @doc """
  Inject a message into a session, optionally targeting a specific
  (non-primary) agent. If `target_agent_id` is nil or `"primary"`,
  delegates to `Worker.submit/3` on the primary. Otherwise delivers
  a signal directly to the target agent's mailbox.
  """
  @spec inject(String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def inject(session_id, target_agent_id, message, opts \\ []) do
    if target_agent_id in [nil, "primary"] do
      case whereis(session_id) do
        nil -> {:error, :session_not_found}
        pid -> Worker.submit(pid, message, opts)
      end
    else
      case Worker.whereis(target_agent_id) do
        nil ->
          {:error, :agent_not_found}

        pid ->
          from = opts[:from] || "external"

          Worker.deliver_signal(pid, %{
            type: "rho.message.sent",
            data: %{message: message, from: from}
          })

          {:ok, :injected}
      end
    end
  end

  # --- Private ---

  defp ensure_event_log(session_id, workspace) do
    case Registry.lookup(Rho.EventLogRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        try do
          DynamicSupervisor.start_child(
            Rho.Agent.EventLog.Supervisor,
            {Rho.Agent.EventLog, session_id: session_id, workspace: workspace}
          )
        catch
          :exit, _ -> :ok
        end
    end
  end
end
