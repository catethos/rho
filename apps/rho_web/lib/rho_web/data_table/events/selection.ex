defmodule RhoWeb.DataTable.Events.Selection do
  @moduledoc false

  alias RhoWeb.DataTable.Rows

  def handle_event("toggle_row_selection", %{"row-id" => id}, socket) do
    table = socket.assigns[:active_table] || "main"
    send(self(), {:data_table_toggle_row, table, id})
    {:noreply, socket}
  end

  def handle_event("toggle_all_selection", _params, socket) do
    table = socket.assigns[:active_table] || "main"
    visible_ids = Rows.visible_row_ids(socket.assigns[:rows])
    send(self(), {:data_table_toggle_all, table, visible_ids})
    {:noreply, socket}
  end

  def handle_event("clear_selection", _params, socket) do
    table = socket.assigns[:active_table] || "main"
    send(self(), {:data_table_clear_selection, table})
    {:noreply, socket}
  end
end
