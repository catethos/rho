defmodule RhoWeb.AppLiveWorkspaceEventsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.AppLive.WorkspaceEvents
  alias RhoWeb.Session.Shell

  test "opening Workbench actions also keeps chat visible" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        shell: Shell.init([], [:data_table]),
        workspaces: %{},
        ws_states: %{},
        active_workspace_id: nil,
        workbench_home_open?: false,
        session_id: nil
      }
    }

    assert {:noreply, socket} = WorkspaceEvents.handle_event("open_workbench_home", %{}, socket)
    assert socket.assigns.active_workspace_id == :data_table
    assert socket.assigns.workbench_home_open?
    assert socket.assigns.shell.chat_mode == :expanded
    assert Map.has_key?(socket.assigns.workspaces, :data_table)
  end
end
