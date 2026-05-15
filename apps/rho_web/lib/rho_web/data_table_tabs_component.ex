defmodule RhoWeb.DataTableTabsComponent do
  @moduledoc false

  use Phoenix.Component

  alias RhoWeb.DataTable.Artifacts
  alias RhoWeb.DataTable.Tabs

  attr(:active_table, :string, required: true)
  attr(:myself, :any, required: true)
  attr(:table_order, :list, default: [])
  attr(:tables, :list, default: [])
  attr(:workbench_context, :any, default: nil)

  def tabs(assigns) do
    ~H"""
    <%= if length(Tabs.display_order(@table_order, @tables)) > 1 do %>
      <div class="dt-tab-strip">
        <%= for name <- Tabs.display_order(@table_order, @tables) do %>
          <% count = Tabs.row_count(@tables, name) %>
          <% artifact = Artifacts.artifact_for_table(@workbench_context, name) %>
          <span class={"dt-tab-shell" <> if(name == @active_table, do: " dt-tab-active", else: "")}>
            <button
              type="button"
              phx-click="select_tab"
              phx-target={@myself}
              phx-value-table={name}
              class="dt-tab"
              title={name}
            >
              <span class="dt-tab-label"><%= Artifacts.tab_label(artifact, name) %></span>
              <span class="dt-tab-count"><%= Artifacts.tab_meta(artifact, count) %></span>
            </button>
            <button
              :if={Tabs.closable?(name)}
              type="button"
              class="dt-tab-close"
              phx-click="close_tab"
              phx-target={@myself}
              phx-value-table={name}
              title={"Close " <> Artifacts.tab_label(artifact, name)}
            >
              &times;
            </button>
          </span>
        <% end %>
      </div>
    <% end %>
    """
  end
end
