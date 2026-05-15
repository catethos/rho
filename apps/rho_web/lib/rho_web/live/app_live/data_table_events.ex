defmodule RhoWeb.AppLive.DataTableEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [send_update: 2]
  require Logger

  alias RhoWeb.Session.SignalRouter
  alias RhoWeb.Session.Shell
  alias RhoWeb.Workspace.Registry, as: WorkspaceRegistry

  def handle_info({:data_table_refresh, table_name}, socket) do
    {:noreply, refresh_active(socket, table_name)}
  end

  def handle_info({:data_table_switch_tab, name}, socket) do
    sid = socket.assigns.session_id
    state = read_state(socket)

    if name != state.active_table do
      publish_view_focus(sid, name)
    end

    new_state = %{state | active_table: name, view_key: nil, mode_label: nil}

    new_state =
      case sid && Rho.Stdlib.DataTable.get_table_snapshot(sid, name) do
        {:ok, snap} ->
          %{new_state | active_snapshot: snap, active_version: snap.version, error: nil}

        {:error, :not_running} ->
          %{new_state | active_snapshot: nil, active_version: nil, error: :not_running}

        _ ->
          %{new_state | active_snapshot: nil, active_version: nil}
      end

    {:noreply, SignalRouter.write_ws_state(socket, :data_table, new_state)}
  end

  def handle_info({:data_table_close_tab, name}, socket) when is_binary(name) do
    sid = socket.assigns[:session_id]

    if is_nil(sid) or name == "main" do
      {:noreply, socket}
    else
      state = read_state(socket)

      case Rho.Stdlib.DataTable.drop_table(sid, name) do
        :ok ->
          socket = refresh_tables(socket)

          if state.active_table == name do
            send(
              self(),
              {:data_table_switch_tab, pick_fallback_active_table(read_state(socket))}
            )
          end

          {:noreply, socket}

        {:error, :not_found} ->
          {:noreply, refresh_tables(socket)}

        {:error, reason} ->
          {:noreply, SignalRouter.write_ws_state(socket, :data_table, %{state | error: reason})}
      end
    end
  end

  def handle_info({:data_table_toggle_row, table, id}, socket) do
    state = read_state(socket)
    current = Map.get(state.selections, table, MapSet.new())

    new_set =
      if MapSet.member?(current, id) do
        MapSet.delete(current, id)
      else
        MapSet.put(current, id)
      end

    {:noreply, update_selection(socket, state, table, new_set)}
  end

  def handle_info({:data_table_toggle_all, table, visible_ids}, socket) do
    state = read_state(socket)
    current = Map.get(state.selections, table, MapSet.new())
    visible = MapSet.new(visible_ids)
    all_selected? = visible != MapSet.new() and MapSet.subset?(visible, current)

    new_set =
      if all_selected? do
        MapSet.difference(current, visible)
      else
        MapSet.union(current, visible)
      end

    {:noreply, update_selection(socket, state, table, new_set)}
  end

  def handle_info({:data_table_clear_selection, table}, socket) do
    state = read_state(socket)
    {:noreply, update_selection(socket, state, table, MapSet.new())}
  end

  def handle_info({:data_table_view_change, view_key, mode_label}, socket) do
    state = read_state(socket)
    new_state = %{state | view_key: view_key, mode_label: mode_label}
    {:noreply, SignalRouter.write_ws_state(socket, :data_table, new_state)}
  end

  def handle_info({:data_table_error, reason}, socket) do
    state = read_state(socket)
    new_state = %{state | error: reason}
    {:noreply, SignalRouter.write_ws_state(socket, :data_table, new_state)}
  end

  def handle_info(
        {:library_load_complete, table_name, lib_name, lib_version, lib_immutable?},
        socket
      ) do
    state = read_state(socket)

    if state.active_table == table_name do
      version_label = library_version_label(lib_version, lib_immutable?)

      new_state = %{state | mode_label: "Skill Library — #{lib_name}#{version_label}"}
      {:noreply, SignalRouter.write_ws_state(socket, :data_table, new_state)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:data_table_save, table_name, new_name}, socket) do
    {:noreply, RhoWeb.SessionLive.DataTableHelpers.handle_save(socket, table_name, new_name)}
  end

  def handle_info({:data_table_fork, table_name}, socket) do
    {:noreply, RhoWeb.SessionLive.DataTableHelpers.handle_fork(socket, table_name)}
  end

  def handle_info({:data_table_publish, table_name, new_name, version_tag}, socket) do
    {:noreply,
     RhoWeb.SessionLive.DataTableHelpers.handle_publish(socket, table_name, new_name, version_tag)}
  end

  def handle_info({:data_table_flash, message}, socket) do
    {:noreply, RhoWeb.SessionLive.DataTableHelpers.set_flash(socket, message)}
  end

  def handle_info({:suggest_skills, n, table_name, session_id}, socket) do
    org = socket.assigns[:current_organization]
    user = socket.assigns[:current_user]

    if is_nil(org) or is_nil(session_id) do
      send(self(), {:data_table_flash, "Suggest unavailable: no active session."})
      {:noreply, socket}
    else
      scope = %RhoFrameworks.Scope{
        organization_id: org.id,
        session_id: session_id,
        user_id: user && user.id,
        source: :agent,
        reason: "user requested suggest_skills"
      }

      lv_pid = self()

      Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
        case RhoFrameworks.UseCases.SuggestSkills.run(%{n: n, table: table_name}, scope) do
          {:ok, %{added: added}} ->
            send(lv_pid, {:suggest_completed, added})

          {:error, reason} ->
            Logger.warning(fn -> "[Suggest] failed: #{inspect(reason)}" end)
            send(lv_pid, {:suggest_failed, reason})
        end
      end)

      {:noreply, socket}
    end
  end

  def handle_info({:suggest_completed, added}, socket) when is_list(added) do
    flash = format_suggest_flash(added)
    expand_groups = added |> Enum.map(fn s -> {s.category, s.cluster} end) |> Enum.uniq()

    send_update(RhoWeb.DataTableComponent,
      id: "workspace-data_table",
      expand_groups: expand_groups
    )

    {:noreply, RhoWeb.SessionLive.DataTableHelpers.set_flash(socket, flash)}
  end

  def handle_info({:suggest_failed, reason}, socket) do
    {:noreply,
     RhoWeb.SessionLive.DataTableHelpers.set_flash(
       socket,
       "Suggest failed: #{inspect(reason)}"
     )}
  end

  def apply_event(socket, %{event: :table_changed} = data) do
    table_name = data[:table_name]
    state = read_state(socket)

    cond do
      is_nil(table_name) ->
        refresh_session(socket)

      table_name != state.active_table ->
        refresh_tables(socket)

      stale_version?(data[:version], state.active_version) ->
        refresh_active(socket, table_name)

      true ->
        socket
    end
  end

  def apply_event(socket, %{event: :table_created}) do
    refresh_session(socket)
  end

  def apply_event(socket, %{event: :table_removed} = data) do
    removed = data[:table_name]
    state = read_state(socket)
    socket = refresh_tables(socket)

    if state.active_table == removed do
      new_state = read_state(socket)
      send(self(), {:data_table_switch_tab, pick_fallback_active_table(new_state)})
    end

    socket
  end

  def apply_event(socket, %{event: :view_change} = data) do
    state = read_state(socket)

    if is_binary(data[:table_name]) and data[:table_name] != state.active_table do
      send(self(), {:data_table_switch_tab, data[:table_name]})
    end

    metadata = data[:metadata] || %{}

    new_state = %{
      state
      | view_key: data[:view_key],
        mode_label: data[:mode_label],
        metadata: metadata
    }

    SignalRouter.write_ws_state(socket, :data_table, new_state)
  end

  def apply_event(socket, _), do: socket

  def refresh_session(socket) do
    sid = socket.assigns[:session_id]
    state = read_state(socket)

    if is_nil(sid) do
      SignalRouter.write_ws_state(socket, :data_table, state)
    else
      refresh_session_from_server(socket, sid, state)
    end
  end

  def refresh_active(socket, table_name) do
    sid = socket.assigns[:session_id]
    state = read_state(socket)

    if is_nil(sid) or state.active_table != table_name do
      socket
    else
      socket = refresh_tables(socket)
      state = read_state(socket)

      case Rho.Stdlib.DataTable.get_table_snapshot(sid, table_name) do
        {:ok, snap} ->
          new_state = %{state | active_snapshot: snap, active_version: snap.version, error: nil}
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

  def refresh_tables(socket) do
    sid = socket.assigns[:session_id]
    state = read_state(socket)

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

  def read_state(socket) do
    ensure_keys(SignalRouter.read_ws_state(socket, :data_table) || initial_state())
  end

  def load_library_into_data_table(socket, library_id) do
    sid = socket.assigns[:session_id]
    org_id = get_in(socket.assigns, [:current_organization, Access.key(:id)])

    lib =
      RhoFrameworks.Library.get_library(org_id, library_id) ||
        RhoFrameworks.Library.get_visible_library!(org_id, library_id)

    if is_nil(lib) do
      socket
    else
      load_library_rows_into_data_table(socket, sid, lib)
    end
  rescue
    _ -> socket
  end

  def open_workspace(socket) do
    key = :data_table

    if map_key?(socket.assigns.workspaces, key) do
      socket |> assign(:active_workspace_id, key)
    else
      case WorkspaceRegistry.get(key) do
        nil ->
          socket

        ws_mod ->
          shell = socket.assigns.shell |> Shell.add_workspace(key) |> Shell.show_chat()

          socket
          |> assign(:workspaces, Map.put(socket.assigns.workspaces, key, ws_mod))
          |> assign(
            :ws_states,
            Map.put(socket.assigns.ws_states, key, ws_mod.projection().init())
          )
          |> assign(:active_workspace_id, key)
          |> assign(:shell, shell)
      end
    end
  end

  def publish_view_focus(nil, _table_name), do: :ok
  def publish_view_focus(_sid, nil), do: :ok

  def publish_view_focus(sid, table_name) when is_binary(sid) and is_binary(table_name) do
    row_count =
      case Rho.Stdlib.DataTable.summarize_table(sid, table: table_name) do
        {:ok, %{total_rows: n}} -> n
        _ -> 0
      end

    event = %Rho.Events.Event{
      kind: :view_focus,
      session_id: sid,
      agent_id: nil,
      timestamp: System.monotonic_time(:millisecond),
      data: %{table_name: table_name, row_count: row_count},
      source: :user
    }

    Rho.Events.broadcast(sid, event)
    :ok
  end

  defp refresh_session_from_server(socket, sid, state) do
    case Rho.Stdlib.DataTable.get_session_snapshot(sid) do
      %{tables: tables, table_order: order} ->
        previous_active = state.active_table

        state =
          %{state | tables: tables, table_order: order, error: nil}
          |> maybe_adopt_default_active()
          |> fetch_active_snapshot(sid)

        if state.active_table != previous_active do
          publish_view_focus(sid, state.active_table)
        end

        SignalRouter.write_ws_state(socket, :data_table, state)

      {:error, :not_running} ->
        SignalRouter.write_ws_state(socket, :data_table, %{state | error: :not_running})

      _ ->
        SignalRouter.write_ws_state(socket, :data_table, state)
    end
  end

  defp initial_state do
    RhoWeb.Projections.DataTableProjection.init()
  end

  defp ensure_keys(state) do
    defaults = initial_state()
    Map.merge(defaults, state)
  end

  defp fetch_active_snapshot(state, sid) do
    case Rho.Stdlib.DataTable.get_table_snapshot(sid, state.active_table) do
      {:ok, snap} ->
        %{state | active_snapshot: snap, active_version: snap.version}

      {:error, :not_running} ->
        %{state | active_snapshot: nil, active_version: nil, error: :not_running}

      _ ->
        state
    end
  end

  defp load_library_rows_into_data_table(socket, sid, lib) do
    table_name = "library:" <> lib.name
    schema = RhoFrameworks.DataTableSchemas.library_schema()
    _ = Rho.Stdlib.DataTable.ensure_started(sid)
    :ok = Rho.Stdlib.DataTable.ensure_table(sid, table_name, schema)
    parent = self()

    Task.start(fn ->
      rows = RhoFrameworks.Library.load_library_rows(lib.id)

      if rows != [] do
        Rho.Stdlib.DataTable.replace_all(sid, rows, table: table_name)
      end

      send(parent, {:library_load_complete, table_name, lib.name, lib.version, lib.immutable})
    end)

    version_label = library_version_label(lib.version, lib.immutable)
    state = read_state(socket)

    new_state = %{
      state
      | active_table: table_name,
        view_key: :skill_library,
        mode_label: "Skill Library — #{lib.name}#{version_label} (loading…)",
        metadata: library_workbench_metadata(lib, table_name)
    }

    if state.active_table != table_name do
      publish_view_focus(sid, table_name)
    end

    socket
    |> open_workspace()
    |> SignalRouter.write_ws_state(:data_table, new_state)
    |> refresh_session()
  rescue
    _ -> socket
  end

  defp library_version_label(version, _immutable?) when not is_nil(version), do: " v#{version}"
  defp library_version_label(_version, true), do: ""
  defp library_version_label(_version, _immutable?), do: " (draft)"

  defp library_workbench_metadata(lib, table_name) do
    %{
      workflow: :edit_existing,
      artifact_kind: :skill_library,
      title: "#{lib.name} Skill Framework",
      library_name: lib.name,
      output_table: table_name,
      library_id: lib.id,
      persisted?: true,
      published?: lib.immutable,
      dirty?: false,
      source_label: library_source_label(lib.version, lib.immutable)
    }
  end

  defp library_source_label(version, _immutable?) when not is_nil(version),
    do: "Loaded v#{version}"

  defp library_source_label(_version, true), do: "Loaded standard"
  defp library_source_label(_version, _immutable?), do: "Loaded draft"

  defp maybe_adopt_default_active(%{active_table: active, table_order: order} = state) do
    cond do
      is_binary(active) and active in order -> state
      "main" in order -> %{state | active_table: "main"}
      order != [] -> %{state | active_table: hd(order)}
      true -> state
    end
  end

  defp pick_fallback_active_table(%{table_order: order}) do
    cond do
      "main" in order -> "main"
      order != [] -> hd(order)
      true -> "main"
    end
  end

  defp stale_version?(version, current) do
    not (is_integer(version) and is_integer(current) and version <= current)
  end

  defp update_selection(socket, state, table, %MapSet{} = new_set) do
    sid = socket.assigns[:session_id]
    ids = MapSet.to_list(new_set)

    if is_binary(sid) do
      Rho.Stdlib.DataTable.set_selection(sid, table, ids)
    end

    publish_row_selection(sid, table, ids)
    new_state = %{state | selections: Map.put(state.selections, table, new_set)}
    SignalRouter.write_ws_state(socket, :data_table, new_state)
  end

  defp publish_row_selection(nil, _table, _ids), do: :ok
  defp publish_row_selection(_sid, nil, _ids), do: :ok

  defp publish_row_selection(sid, table, ids)
       when is_binary(sid) and is_binary(table) and is_list(ids) do
    event = %Rho.Events.Event{
      kind: :row_selection,
      session_id: sid,
      agent_id: nil,
      timestamp: System.monotonic_time(:millisecond),
      data: %{table_name: table, row_ids: ids},
      source: :user
    }

    Rho.Events.broadcast(sid, event)
    :ok
  end

  defp format_suggest_flash([]), do: "Suggest returned no skills."

  defp format_suggest_flash(added) do
    count = length(added)

    "Added #{count} #{if count == 1 do
      "skill"
    else
      "skills"
    end}"
  end

  defp map_key?(map, key) do
    case Map.fetch(map, key) do
      {:ok, _} -> true
      :error -> false
    end
  end
end
