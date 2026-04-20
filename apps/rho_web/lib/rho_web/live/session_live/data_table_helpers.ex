defmodule RhoWeb.SessionLive.DataTableHelpers do
  @moduledoc """
  Data table snapshot-cache helpers extracted from `RhoWeb.SessionLive`.

  Handles refreshing data table state in socket assigns via the
  `SignalRouter` workspace state mechanism.
  """

  import Phoenix.Component, only: [assign: 3]

  alias RhoWeb.Session.SignalRouter
  alias RhoWeb.Session.Shell
  alias RhoWeb.Workspace.Registry, as: WorkspaceRegistry

  # -- Public API (called from SessionLive) --

  @doc """
  Refetch the session-level table list (tab strip) plus the active
  table's rows. Used on mount and on :table_created.
  """
  def refresh_data_table_session(socket) do
    sid = socket.assigns[:session_id]
    state = ensure_dt_keys(read_dt_state(socket))

    if is_nil(sid) do
      SignalRouter.write_ws_state(socket, :data_table, state)
    else
      state = merge_session_snapshot(sid, state)
      SignalRouter.write_ws_state(socket, :data_table, state)
    end
  end

  @doc """
  Refetch only the tab list (no active-table snapshot).
  """
  def refresh_data_table_tables(socket) do
    sid = socket.assigns[:session_id]
    state = ensure_dt_keys(read_dt_state(socket))

    if is_nil(sid) do
      socket
    else
      case Rho.Stdlib.DataTable.get_session_snapshot(sid) do
        %{tables: tables, table_order: order} ->
          SignalRouter.write_ws_state(socket, :data_table, %{
            state
            | tables: tables,
              table_order: order
          })

        _ ->
          socket
      end
    end
  end

  @doc """
  Refetch only the active table's rows (fastest path for frequent
  :table_changed events).
  """
  def refresh_data_table_active(socket, table_name) do
    sid = socket.assigns[:session_id]
    state = ensure_dt_keys(read_dt_state(socket))

    cond do
      is_nil(sid) ->
        socket

      state.active_table != table_name ->
        socket

      true ->
        # Refresh tab counts for all tables alongside the active snapshot
        socket = refresh_data_table_tables(socket)

        state = ensure_dt_keys(read_dt_state(socket))

        case Rho.Stdlib.DataTable.get_table_snapshot(sid, table_name) do
          {:ok, snap} ->
            new_state = %{
              state
              | active_snapshot: snap,
                active_version: snap.version,
                error: nil
            }

            SignalRouter.write_ws_state(socket, :data_table, new_state)

          {:error, :not_running} ->
            SignalRouter.write_ws_state(socket, :data_table, %{state | error: :not_running})

          {:error, :not_found} ->
            SignalRouter.write_ws_state(socket, :data_table, %{
              state
              | active_snapshot: nil,
                active_version: nil
            })

          _ ->
            socket
        end
    end
  end

  @doc """
  Handle a coarse invalidation event from the per-session DataTable
  server. `data` is a map with an `:event` key.
  """
  def apply_data_table_event(socket, data) when is_map(data) do
    case data[:event] do
      :table_changed ->
        handle_table_changed(socket, data)

      :table_created ->
        refresh_data_table_session(socket)

      :table_removed ->
        removed = data[:table_name]

        state = ensure_dt_keys(read_dt_state(socket))

        socket = refresh_data_table_tables(socket)

        if state.active_table == removed do
          new_state = ensure_dt_keys(read_dt_state(socket))

          fallback = pick_fallback_active_table(new_state)
          send(self(), {:data_table_switch_tab, fallback})
        end

        socket

      :view_change ->
        view_key = data[:view_key]
        mode_label = data[:mode_label]
        table_name = data[:table_name]

        state = ensure_dt_keys(read_dt_state(socket))

        if is_binary(table_name) and table_name != state.active_table do
          send(self(), {:data_table_switch_tab, table_name})
        end

        new_state = %{state | view_key: view_key, mode_label: mode_label}
        SignalRouter.write_ws_state(socket, :data_table, new_state)

      _ ->
        socket
    end
  end

  def apply_data_table_event(socket, _), do: socket

  defp handle_table_changed(socket, data) do
    table_name = data[:table_name]
    state = ensure_dt_keys(read_dt_state(socket))

    cond do
      is_nil(table_name) ->
        refresh_data_table_session(socket)

      table_name == state.active_table ->
        already_current? =
          is_integer(data[:version]) and is_integer(state.active_version) and
            data[:version] <= state.active_version

        if already_current?, do: socket, else: refresh_data_table_active(socket, table_name)

      true ->
        refresh_data_table_tables(socket)
    end
  end

  @doc """
  Handle a workspace_open signal from the EffectDispatcher.
  """
  def apply_open_workspace_event(socket, data) when is_map(data) do
    key = data[:key]

    cond do
      not is_atom(key) or is_nil(key) ->
        socket

      Map.has_key?(socket.assigns.workspaces, key) ->
        # Already mounted — just focus it.
        socket
        |> assign(:active_workspace_id, key)
        |> assign(:shell, Shell.clear_activity(socket.assigns.shell, key))

      true ->
        case WorkspaceRegistry.get(key) do
          nil -> socket
          ws_mod -> mount_workspace(socket, key, ws_mod)
        end
    end
  end

  def apply_open_workspace_event(socket, _), do: socket

  defp mount_workspace(socket, key, ws_mod) do
    shell =
      socket.assigns.shell
      |> Shell.add_workspace(key)
      |> Shell.show_chat()

    socket =
      socket
      |> assign(:workspaces, Map.put(socket.assigns.workspaces, key, ws_mod))
      |> assign(:ws_states, Map.put(socket.assigns.ws_states, key, ws_mod.projection().init()))
      |> assign(:active_workspace_id, key)
      |> assign(:shell, shell)

    if key == :data_table, do: refresh_data_table_session(socket), else: socket
  end

  @doc """
  Returns the initial data table projection state.
  """
  def dt_initial_state, do: RhoWeb.Projections.DataTableProjection.init()

  @doc """
  Backfill keys added after initial state shape so stale ws_state
  maps don't crash on struct-update syntax.
  """
  def ensure_dt_keys(state) do
    defaults = dt_initial_state()
    Map.merge(defaults, state)
  end

  def pick_fallback_active_table(%{table_order: order}) do
    cond do
      "main" in order -> "main"
      order != [] -> hd(order)
      true -> "main"
    end
  end

  # -- Save / Fork actions --

  @doc """
  Save the active data table rows back to their library.
  If `new_name` differs from the current name, renames the library first.
  """
  def handle_save(socket, table_name, new_name) do
    sid = socket.assigns[:session_id]
    org_id = get_in(socket.assigns, [:current_organization, Access.key(:id)])

    with {:ok, lib_name} <- extract_library_name(table_name),
         lib when not is_nil(lib) <- RhoFrameworks.Library.resolve_library(org_id, lib_name),
         {:ok, effective_table} <- maybe_rename_library(lib, new_name, sid, table_name),
         rows when is_list(rows) and rows != [] <-
           Rho.Stdlib.DataTable.get_rows(sid, table: effective_table) do
      case RhoFrameworks.Library.save_to_library(org_id, lib.id, rows) do
        {:ok, %{skills: skills}} ->
          count = length(skills)
          send(self(), {:data_table_flash, "Saved #{count} skill(s)."})
          socket

        {:error, reason} ->
          send(self(), {:data_table_flash, "Save failed: #{inspect(reason)}"})
          socket
      end
    else
      {:error, :not_library} ->
        send(self(), {:data_table_flash, "Save is only available for library tables."})
        socket

      {:error, :not_running} ->
        send(self(), {:data_table_flash, "Table server not running."})
        socket

      {:error, :rename_failed} ->
        send(self(), {:data_table_flash, "Failed to rename library."})
        socket

      nil ->
        send(self(), {:data_table_flash, "Library not found."})
        socket

      [] ->
        send(self(), {:data_table_flash, "Table is empty — nothing to save."})
        socket

      _ ->
        send(self(), {:data_table_flash, "Save failed."})
        socket
    end
  end

  @doc """
  Fork the current library into a mutable working copy.
  Auto-generates a name like "My <library_name>".
  """
  def handle_fork(socket, table_name) do
    org_id = get_in(socket.assigns, [:current_organization, Access.key(:id)])

    with {:ok, lib_name} <- extract_library_name(table_name),
         lib when not is_nil(lib) <- RhoFrameworks.Library.resolve_library(org_id, lib_name) do
      fork_name = "My #{lib.name}"

      case RhoFrameworks.Library.fork_library(org_id, lib.id, fork_name) do
        {:ok, %{library: forked, skills: skill_map}} ->
          count = map_size(skill_map)
          send(self(), {:data_table_flash, "Forked '#{forked.name}' — #{count} skills."})
          socket

        {:error, _step, reason, _} ->
          send(self(), {:data_table_flash, "Fork failed: #{inspect(reason)}"})
          socket
      end
    else
      {:error, :not_library} ->
        send(self(), {:data_table_flash, "Fork is only available for library tables."})
        socket

      nil ->
        send(self(), {:data_table_flash, "Library not found."})
        socket

      _ ->
        send(self(), {:data_table_flash, "Fork failed."})
        socket
    end
  end

  @doc """
  Set a transient flash message on the data table component.
  """
  def set_flash(socket, message) do
    state = ensure_dt_keys(read_dt_state(socket))
    new_state = Map.put(state, :flash_message, message)
    SignalRouter.write_ws_state(socket, :data_table, new_state)
  end

  @doc """
  Publish the current draft library as an immutable versioned snapshot.
  Auto-saves in-memory rows first, optionally renames, then stamps a version tag.
  """
  def handle_publish(socket, table_name, new_name, version_tag) do
    sid = socket.assigns[:session_id]
    org_id = get_in(socket.assigns, [:current_organization, Access.key(:id)])

    with {:ok, lib_name} <- extract_library_name(table_name),
         lib when not is_nil(lib) <- RhoFrameworks.Library.resolve_library(org_id, lib_name),
         {:ok, effective_table} <- maybe_rename_library(lib, new_name, sid, table_name) do
      # Sync in-memory rows to DB before publishing
      case Rho.Stdlib.DataTable.get_rows(sid, table: effective_table) do
        rows when is_list(rows) and rows != [] ->
          RhoFrameworks.Library.save_to_library(lib.id, rows)

        _ ->
          :ok
      end

      result = RhoFrameworks.Library.publish_version(org_id, lib.id, version_tag)

      case result do
        {:ok, published} ->
          send(
            self(),
            {:data_table_flash, "Published '#{published.name}' v#{published.version}."}
          )

          socket

        {:error, :already_published, msg} ->
          send(self(), {:data_table_flash, msg})
          socket

        {:error, :version_exists, msg} ->
          send(self(), {:data_table_flash, msg})
          socket

        {:error, :not_found} ->
          send(self(), {:data_table_flash, "Library not found for publishing."})
          socket

        {:error, reason} ->
          send(self(), {:data_table_flash, "Publish failed: #{inspect(reason)}"})
          socket

        other ->
          require Logger
          Logger.error("Unexpected publish result: #{inspect(other)}")
          send(self(), {:data_table_flash, "Publish failed unexpectedly."})
          socket
      end
    else
      {:error, :not_library} ->
        send(self(), {:data_table_flash, "Publish is only available for library tables."})
        socket

      {:error, :rename_failed} ->
        send(self(), {:data_table_flash, "Failed to rename library."})
        socket

      nil ->
        send(self(), {:data_table_flash, "Library not found."})
        socket

      _ ->
        send(self(), {:data_table_flash, "Publish failed."})
        socket
    end
  end

  defp extract_library_name("library:" <> name), do: {:ok, name}
  defp extract_library_name(_), do: {:error, :not_library}

  defp maybe_rename_library(%{name: current_name}, new_name, _sid, old_table_name)
       when new_name == current_name or new_name == "" do
    {:ok, old_table_name}
  end

  defp maybe_rename_library(lib, new_name, sid, old_table_name) do
    case RhoFrameworks.Library.rename_library(lib.organization_id, lib.id, new_name) do
      {:ok, _} ->
        new_table_name = "library:" <> new_name
        rename_data_table(sid, old_table_name, new_table_name)
        {:ok, new_table_name}

      {:error, _} ->
        {:error, :rename_failed}
    end
  end

  defp rename_data_table(sid, old_name, new_name) when old_name != new_name do
    # Copy rows to new table, drop old one, switch tab
    schema = RhoFrameworks.DataTableSchemas.library_schema()

    with rows when is_list(rows) <- Rho.Stdlib.DataTable.get_rows(sid, table: old_name),
         :ok <- Rho.Stdlib.DataTable.ensure_table(sid, new_name, schema),
         {:ok, _} <- Rho.Stdlib.DataTable.replace_all(sid, rows, table: new_name) do
      Rho.Stdlib.DataTable.drop_table(sid, old_name)
      send(self(), {:data_table_switch_tab, new_name})
      :ok
    else
      _ -> :ok
    end
  end

  defp rename_data_table(_, _, _), do: :ok

  # -- Private --

  defp read_dt_state(socket) do
    SignalRouter.read_ws_state(socket, :data_table) || dt_initial_state()
  end

  defp merge_session_snapshot(sid, state) do
    case Rho.Stdlib.DataTable.get_session_snapshot(sid) do
      %{tables: tables, table_order: order} ->
        state = %{state | tables: tables, table_order: order, error: nil}
        state = maybe_adopt_default_active(state)
        apply_active_table_snapshot(sid, state)

      {:error, :not_running} ->
        %{state | error: :not_running}

      _ ->
        state
    end
  end

  defp apply_active_table_snapshot(sid, state) do
    case Rho.Stdlib.DataTable.get_table_snapshot(sid, state.active_table) do
      {:ok, snap} ->
        %{state | active_snapshot: snap, active_version: snap.version}

      {:error, :not_running} ->
        %{state | active_snapshot: nil, active_version: nil, error: :not_running}

      _ ->
        state
    end
  end

  defp maybe_adopt_default_active(%{active_table: active, table_order: order} = state) do
    cond do
      is_binary(active) and active in order -> state
      "main" in order -> %{state | active_table: "main"}
      order != [] -> %{state | active_table: hd(order)}
      true -> state
    end
  end
end
