defmodule RhoWeb.DataTableSelectionBarComponent do
  @moduledoc false

  use Phoenix.Component

  alias RhoWeb.DataTable.Artifacts

  attr(:active_artifact, :any, default: nil)
  attr(:myself, :any, required: true)
  attr(:selected_ids, :any, default: MapSet.new())

  def selection_bar(assigns) do
    assigns = assign(assigns, :selected_count, MapSet.size(assigns.selected_ids))

    ~H"""
    <%= if @selected_count > 0 do %>
      <div class="dt-selection-bar">
        <span class="dt-selection-count">
          <%= @selected_count %> <%= Artifacts.selection_noun(@active_artifact, @selected_count) %> selected
        </span>
        <button
          type="button"
          class="dt-selection-clear"
          phx-click="clear_selection"
          phx-target={@myself}
        >
          Clear
        </button>
      </div>
    <% end %>
    """
  end
end
