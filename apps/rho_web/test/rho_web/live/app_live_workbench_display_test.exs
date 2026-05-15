defmodule RhoWeb.AppLiveWorkbenchDisplayTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias RhoWeb.AppLive
  alias RhoWeb.AppLive.WorkbenchDisplayState
  alias RhoWeb.Projections.DataTableProjection
  alias RhoWeb.Session.Shell
  alias RhoWeb.WorkbenchDisplay

  test "workbench display state initializes legacy and explicit display assigns together" do
    socket = WorkbenchDisplayState.initial_assigns(%Socket{assigns: %{__changed__: %{}}})

    refute socket.assigns.workbench_home_open?
    assert %WorkbenchDisplay{mode: :home} = socket.assigns.workbench_display
  end

  test "workbench display state builds shared workspace assigns" do
    display =
      WorkbenchDisplay.from_data_state(%{table_order: [], tables: [], active_table: "main"})

    assigns = %{
      session_id: "s1",
      agents: %{primary: %{name: "Agent"}},
      workbench_home_open?: true,
      workbench_display: display,
      total_cost: 1.25
    }

    shared =
      WorkbenchDisplayState.shared_assigns(assigns,
        active_agent_name: "Agent",
        workbench_libraries: [%{name: "Core"}],
        chat_mode: :split,
        streaming: true
      )

    assert shared.session_id == "s1"
    assert shared.active_agent_name == "Agent"
    assert shared.workbench_libraries == [%{name: "Core"}]
    assert shared.chat_mode == :split
    assert shared.workbench_home_open?
    assert shared.workbench_display == display
    assert shared.streaming
    assert shared.total_cost == 1.25
  end

  test "workbench_home_open message switches display mode to home" do
    socket =
      socket_with_data_state(%{table_order: ["library:Core"], active_table: "library:Core"})

    assert {:noreply, socket} = AppLive.handle_info({:workbench_home_open, true}, socket)
    assert socket.assigns.workbench_home_open?
    assert %WorkbenchDisplay{mode: :home} = socket.assigns.workbench_display
  end

  test "data_table_switch_tab message switches display mode to the table" do
    socket =
      socket_with_data_state(%{
        table_order: ["library:Core"],
        tables: [%{name: "library:Core", row_count: 1}],
        active_table: "main"
      })

    assert {:noreply, socket} =
             AppLive.handle_info({:data_table_switch_tab, "library:Core"}, socket)

    refute socket.assigns.workbench_home_open?
    assert %WorkbenchDisplay{mode: {:table, "library:Core"}} = socket.assigns.workbench_display
  end

  defp socket_with_data_state(overrides) do
    data_state = Map.merge(DataTableProjection.init(), overrides)

    %Socket{
      assigns: %{
        __changed__: %{},
        session_id: nil,
        shell: Shell.init([], [:data_table]),
        workspaces: %{},
        ws_states: %{data_table: data_state},
        active_workspace_id: nil,
        workbench_home_open?: false,
        workbench_display: WorkbenchDisplay.from_data_state(data_state)
      }
    }
  end
end
