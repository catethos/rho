defmodule RhoWeb.DataTable.Events.Navigation do
  @moduledoc false

  def handle_event("select_tab", %{"table" => name}, socket) do
    send(self(), {:workbench_home_open, false})
    send(self(), {:data_table_switch_tab, name})
    {:noreply, socket}
  end

  def handle_event("close_tab", %{"table" => name}, socket) do
    send(self(), {:data_table_close_tab, name})
    {:noreply, socket}
  end

  def handle_event("show_workbench_home", _params, socket) do
    send(self(), {:workbench_home_open, true})
    {:noreply, socket}
  end

  def handle_event("hide_workbench_home", _params, socket) do
    send(self(), {:workbench_home_open, false})
    {:noreply, socket}
  end

  def handle_event("workbench_action_open", %{"action" => action_id}, socket) do
    send(self(), {:workbench_action_open, action_id})
    {:noreply, socket}
  end

  def handle_event("workbench_library_open", %{"library-id" => library_id}, socket) do
    send(self(), {:workbench_library_open, library_id})
    {:noreply, socket}
  end

  def handle_event("navigate_to_library", %{"library-id" => library_id}, socket) do
    send(self(), {:navigate_to_library, library_id})
    {:noreply, socket}
  end

  def handle_event("candidates_done", _params, socket) do
    send(self(), {:role_candidates_done})
    {:noreply, socket}
  end
end
