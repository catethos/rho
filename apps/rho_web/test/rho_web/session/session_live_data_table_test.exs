defmodule RhoWeb.SessionLiveDataTableTest do
  @moduledoc """
  End-to-end tests for the DataTable snapshot-cache flow in SessionLive.

  These exercise the full path: the per-session DataTable server
  publishes a `:table_changed` invalidation event via `Rho.Events`, the
  LV's `handle_info` routes it through `apply_data_table_event/2`, and
  the workspace state in `ws_states` is updated with a fresh snapshot.

  We drive this through `Rho.Events.Event` delivery directly since
  spinning up a full authenticated connected LiveView is heavy.
  """
  use ExUnit.Case, async: false

  alias RhoWeb.Projections.DataTableProjection
  alias Rho.Stdlib.DataTable

  setup do
    session_id = "lvtest_#{System.unique_integer([:positive])}"
    on_exit(fn -> DataTable.stop(session_id) end)
    {:ok, session_id: session_id}
  end

  defp build_socket(session_id) do
    assigns = %{
      __changed__: %{},
      live_action: :show,
      session_id: session_id,
      workspaces: %{
        data_table: %{
          label: "Skills Editor",
          icon: "table",
          projection: DataTableProjection
        }
      },
      ws_states: %{data_table: DataTableProjection.init()},
      active_workspace_id: :data_table,
      shell: RhoWeb.Session.Shell.init([], []),
      agents: %{},
      active_agent_id: nil,
      agent_tab_order: [],
      inflight: %{},
      signals: [],
      agent_messages: %{},
      ui_streams: %{},
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cost: 0.0,
      total_cached_tokens: 0,
      total_reasoning_tokens: 0,
      step_input_tokens: 0,
      step_output_tokens: 0,
      connected: true,
      user_avatar: nil,
      agent_avatar: nil,
      active_page: :chat,
      selected_agent_id: nil,
      timeline_open: false,
      drawer_open: false,
      show_new_agent: false,
      uploaded_files: [],
      debug_mode: false,
      debug_projections: %{},
      next_id: 1
    }

    struct!(Phoenix.LiveView.Socket, assigns: assigns)
  end

  # Build a Rho.Events.Event matching what DataTable.Server publishes.
  defp dt_event(session_id, payload) do
    Rho.Events.event(:data_table, session_id, nil, payload)
  end

  describe "snapshot refetch on table_changed" do
    test "refetches active snapshot and updates version", %{session_id: sid} do
      {:ok, _} = DataTable.ensure_started(sid)
      {:ok, _} = DataTable.add_rows(sid, [%{"name" => "foo"}, %{"name" => "bar"}])

      socket = build_socket(sid)

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_info(
          dt_event(sid, %{
            event: :table_changed,
            table_name: "main",
            version: 99
          }),
          socket
        )

      state = socket.assigns.ws_states[:data_table]
      assert state.active_snapshot != nil
      assert length(state.active_snapshot.rows) == 2
      assert state.active_version == state.active_snapshot.version
      assert state.error == nil
    end

    test "ignores events with stale version", %{session_id: sid} do
      {:ok, _} = DataTable.ensure_started(sid)

      socket = build_socket(sid)

      state =
        socket.assigns.ws_states[:data_table]
        |> Map.put(:active_version, 100)
        |> Map.put(:active_snapshot, %{rows: [], version: 100})

      socket = %{
        socket
        | assigns: Map.put(socket.assigns, :ws_states, %{data_table: state})
      }

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_info(
          dt_event(sid, %{
            event: :table_changed,
            table_name: "main",
            version: 50
          }),
          socket
        )

      # Version unchanged because 50 <= 100
      assert socket.assigns.ws_states[:data_table].active_version == 100
    end

    test "surfaces :not_running error when server is down after event", %{session_id: sid} do
      # Don't start the server; the event triggers a refetch attempt.
      socket = build_socket(sid)

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_info(
          dt_event(sid, %{
            event: :table_changed,
            table_name: "main",
            version: 1
          }),
          socket
        )

      state = socket.assigns.ws_states[:data_table]
      assert state.error == :not_running
    end
  end

  describe "view_change event" do
    test "updates view_key and mode_label without touching rows", %{session_id: sid} do
      {:ok, _} = DataTable.ensure_started(sid)
      socket = build_socket(sid)

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_info(
          dt_event(sid, %{
            event: :view_change,
            view_key: :skill_library,
            mode_label: "Skill Library — Demo",
            table_name: "main"
          }),
          socket
        )

      state = socket.assigns.ws_states[:data_table]
      assert state.view_key == :skill_library
      assert state.mode_label == "Skill Library — Demo"
    end
  end

  describe "tab switching" do
    test "switches active_table and refetches its snapshot", %{session_id: sid} do
      {:ok, _} = DataTable.ensure_started(sid)
      schema = Rho.Stdlib.DataTable.Schema.dynamic("library")
      :ok = DataTable.ensure_table(sid, "library", schema)
      {:ok, _} = DataTable.add_rows(sid, [%{"name" => "lib_row"}], table: "library")

      socket = build_socket(sid)

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_info({:data_table_switch_tab, "library"}, socket)

      state = socket.assigns.ws_states[:data_table]
      assert state.active_table == "library"
      assert length(state.active_snapshot.rows) == 1
    end
  end
end
