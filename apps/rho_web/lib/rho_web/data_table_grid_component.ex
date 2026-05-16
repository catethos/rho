defmodule RhoWeb.DataTableGridComponent do
  @moduledoc false

  use Phoenix.Component

  alias RhoWeb.DataTable.RowComponents
  alias RhoWeb.DataTable.Rows
  alias RhoWeb.DataTable.Streams

  attr(:collapsed, :any, required: true)
  attr(:confirm_delete, :any, default: nil)
  attr(:editing, :any, default: nil)
  attr(:editing_group, :any, default: nil)
  attr(:group_to_stream, :map, default: %{})
  attr(:grouped, :list, default: [])
  attr(:metadata, :map, default: %{})
  attr(:myself, :any, required: true)
  attr(:schema, :map, required: true)
  attr(:select_all_state, :atom, default: :none)
  attr(:selected_ids, :any, default: MapSet.new())
  attr(:sort_by, :atom, default: nil)
  attr(:sort_dir, :atom, default: :asc)
  attr(:streamed_groups, :map, default: %{})
  attr(:streams, :map, default: %{})

  def grid(assigns) do
    ~H"""
    <div class="dt-table-wrap">
      <%= if @grouped == [] do %>
        <div class="dt-empty"><%= @schema.empty_message %></div>
      <% else %>
        <%= if @schema.group_by == [] do %>
          <% {group_label, {:rows, _rows}} = List.first(@grouped) %>
          <% group_id = "grp-" <> slug(group_label) %>
          <% stream_atom = Map.get(@group_to_stream, group_id) %>
          <.data_table_rows
            stream={stream_atom && Map.get(@streams, stream_atom)}
            group_id={group_id}
            more_pages?={more_pages?(@streamed_groups, group_id)}
            schema={@schema}
            editing={@editing}
            myself={@myself}
            collapsed={@collapsed}
            metadata={@metadata}
            sort_by={@sort_by}
            sort_dir={@sort_dir}
            confirm_delete={@confirm_delete}
            selected_ids={@selected_ids}
            select_all_state={@select_all_state}
          />
          <RowComponents.add_row_in_group myself={@myself} group_by={[]} group_label={nil} sub_label={nil} />
        <% else %>
          <%= for {group_label, children} <- @grouped do %>
          <% group_id = "grp-" <> slug(group_label) %>
          <% group_by = @schema.group_by %>
          <% l1_field = List.first(group_by) %>
          <div id={group_id} class={"dt-group dt-group-l1" <> if(collapsed?(@collapsed, group_id), do: " dt-collapsed", else: "")}>
            <div class="dt-group-header dt-group-header-l1">
              <span class="dt-chevron" phx-click="toggle_group" phx-target={@myself} phx-value-group={group_id}></span>
              <.editable_group_name
                field={l1_field}
                value={group_label}
                editing_group={@editing_group}
                myself={@myself}
              />
              <span class="dt-group-count" phx-click="toggle_group" phx-target={@myself} phx-value-group={group_id}><%= Rows.count_nested_rows(children) %> rows</span>
              <button type="button" class="dt-group-add-btn" phx-click="add_row" phx-target={@myself}
                phx-value-category={group_label}
                title={"Add skill to #{group_label}"}>+</button>
            </div>
            <div class={"dt-group-content" <> if(collapsed?(@collapsed, group_id), do: " dt-hidden", else: "")}>
              <%= case children do %>
                <% {:rows, _rows} -> %>
                  <% stream_atom = Map.get(@group_to_stream, group_id) %>
                  <.data_table_rows
                    stream={stream_atom && Map.get(@streams, stream_atom)}
                    group_id={group_id}
                    more_pages?={more_pages?(@streamed_groups, group_id)}
                    schema={@schema}
                    editing={@editing}
                    myself={@myself}
                    collapsed={@collapsed}
                    metadata={@metadata}
                    sort_by={@sort_by}
                    sort_dir={@sort_dir}
                    confirm_delete={@confirm_delete}
                    selected_ids={@selected_ids}
                    select_all_state={@select_all_state}
                  />
                  <RowComponents.add_row_in_group myself={@myself} group_by={group_by} group_label={group_label} sub_label={nil} />
                <% {:nested, sub_groups} -> %>
                  <% l2_field = Enum.at(group_by, 1) %>
                  <%= for {sub_label, rows} <- sub_groups do %>
                    <% sub_id = "grp-" <> slug(group_label) <> "-" <> slug(sub_label) %>
                    <% sub_stream_atom = Map.get(@group_to_stream, sub_id) %>
                    <div id={sub_id} class={"dt-group dt-group-l2" <> if(collapsed?(@collapsed, sub_id), do: " dt-collapsed", else: "")}>
                      <div class="dt-group-header dt-group-header-l2">
                        <span class="dt-chevron" phx-click="toggle_group" phx-target={@myself} phx-value-group={sub_id}></span>
                        <.editable_group_name
                          field={l2_field}
                          value={sub_label}
                          editing_group={@editing_group}
                          myself={@myself}
                        />
                        <span class="dt-group-count" phx-click="toggle_group" phx-target={@myself} phx-value-group={sub_id}><%= length(rows) %> rows</span>
                        <button type="button" class="dt-group-add-btn" phx-click="add_row" phx-target={@myself}
                          phx-value-category={group_label}
                          phx-value-cluster={sub_label}
                          title={"Add skill to #{sub_label}"}>+</button>
                      </div>
                      <div class={"dt-group-content" <> if(collapsed?(@collapsed, sub_id), do: " dt-hidden", else: "")}>
                        <.data_table_rows
                          stream={sub_stream_atom && Map.get(@streams, sub_stream_atom)}
                          group_id={sub_id}
                          more_pages?={more_pages?(@streamed_groups, sub_id)}
                          schema={@schema}
                          editing={@editing}
                          myself={@myself}
                          collapsed={@collapsed}
                          metadata={@metadata}
                          sort_by={@sort_by}
                          sort_dir={@sort_dir}
                          confirm_delete={@confirm_delete}
                          selected_ids={@selected_ids}
                          select_all_state={@select_all_state}
                        />
                        <RowComponents.add_row_in_group myself={@myself} group_by={group_by} group_label={group_label} sub_label={sub_label} />
                      </div>
                    </div>
                  <% end %>
              <% end %>
            </div>
          </div>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp data_table_rows(assigns) do
    visible_columns =
      Enum.reject(assigns.schema.columns, fn col -> col.key in assigns.schema.group_by end)

    has_children = assigns.schema.children_key != nil
    child_columns = assigns.schema.child_columns || []
    children_key = assigns.schema.children_key
    show_id = Map.get(assigns.schema, :show_id, true)
    panel_mode = Map.get(assigns.schema, :children_display, :rows) == :panel
    research_notes? = Map.get(assigns.schema, :row_layout, :table) == :research_notes

    assigns =
      assign(assigns,
        visible_columns: visible_columns,
        has_children: has_children,
        child_columns: child_columns,
        children_key: children_key,
        show_id: show_id,
        panel_mode: panel_mode,
        research_notes?: research_notes?,
        panel_colspan: length(visible_columns) + 5
      )

    ~H"""
    <table class={["dt-table", @research_notes? && "dt-table-research"]}>
      <thead>
        <tr :if={@research_notes?}>
          <th class="dt-th dt-th-select">
            <input
              type="checkbox"
              class="dt-row-checkbox dt-row-checkbox-header"
              phx-click="toggle_all_selection"
              phx-target={@myself}
              checked={@select_all_state == :all}
              data-indeterminate={@select_all_state == :some && "true"}
              aria-label="Select all visible rows"
            />
          </th>
          <th class="dt-th dt-th-source" title="Provenance"></th>
          <th class={"dt-th dt-th-research-note" <> if(@sort_by == :fact, do: " dt-th-sorted", else: "")}
              phx-click="sort_column" phx-target={@myself} phx-value-field={:fact}
              style="cursor: pointer; user-select: none;">
            Finding
            <span :if={@sort_by == :fact} class="dt-sort-indicator">
              <%= if @sort_dir == :asc, do: Phoenix.HTML.raw("&#9650;"), else: Phoenix.HTML.raw("&#9660;") %>
            </span>
          </th>
          <th class={"dt-th dt-th-research-meta" <> if(@sort_by == :source_title, do: " dt-th-sorted", else: "")}
              phx-click="sort_column" phx-target={@myself} phx-value-field={:source_title}
              style="cursor: pointer; user-select: none;">
            Source
            <span :if={@sort_by == :source_title} class="dt-sort-indicator">
              <%= if @sort_dir == :asc, do: Phoenix.HTML.raw("&#9650;"), else: Phoenix.HTML.raw("&#9660;") %>
            </span>
          </th>
          <th class="dt-th dt-th-actions"></th>
        </tr>
        <tr :if={!@research_notes?}>
          <th class="dt-th dt-th-select">
            <input
              type="checkbox"
              class="dt-row-checkbox dt-row-checkbox-header"
              phx-click="toggle_all_selection"
              phx-target={@myself}
              checked={@select_all_state == :all}
              data-indeterminate={@select_all_state == :some && "true"}
              aria-label="Select all visible rows"
            />
          </th>
          <%= if @has_children do %>
            <th class="dt-th dt-th-expand"></th>
          <% end %>
          <th :if={@show_id} class="dt-th dt-th-id">ID</th>
          <th class="dt-th dt-th-source" title="Provenance"></th>
          <th :for={col <- @visible_columns} class={"dt-th " <> (col.css_class || "dt-th-#{col.key}") <> if(@sort_by == col.key, do: " dt-th-sorted", else: "")}
              phx-click="sort_column" phx-target={@myself} phx-value-field={col.key}
              style="cursor: pointer; user-select: none;">
            <%= col.label %>
            <span :if={@sort_by == col.key} class="dt-sort-indicator">
              <%= if @sort_dir == :asc, do: Phoenix.HTML.raw("&#9650;"), else: Phoenix.HTML.raw("&#9660;") %>
            </span>
          </th>
          <%= if @has_children && !@panel_mode do %>
            <th :for={col <- @child_columns} class={"dt-th " <> (col.css_class || "dt-th-#{col.key}")}><%= col.label %></th>
          <% end %>
          <th :if={@has_children && @panel_mode} class="dt-th dt-col-levels">Levels</th>
          <th class="dt-th dt-th-actions"></th>
        </tr>
      </thead>
      <tbody
        id={"rows-tbody-" <> @group_id}
        phx-update="stream"
        phx-viewport-bottom={if @more_pages?, do: "load_more_in_group", else: nil}
        phx-target={@myself}
        phx-value-group={@group_id}
      >
        <%= for {dom_id, row} <- @stream || [] do %>
          <%= case Map.get(row, :_kind) do %>
            <% :panel -> %>
              <RowComponents.proficiency_panel_row
                dom_id={dom_id}
                row={row}
                children_key={@children_key}
                editing={@editing}
                myself={@myself}
                panel_colspan={@panel_colspan}
              />
            <% _ -> %>
              <%= if @research_notes? do %>
                <RowComponents.research_note_row
                  dom_id={dom_id}
                  row={row}
                  editing={@editing}
                  myself={@myself}
                  confirm_delete={@confirm_delete}
                  selected_ids={@selected_ids}
                />
              <% else %>
              <RowComponents.parent_row
                dom_id={dom_id}
                row={row}
                schema={@schema}
                visible_columns={@visible_columns}
                child_columns={@child_columns}
                children_key={@children_key}
                show_id={@show_id}
                has_children={@has_children}
                panel_mode={@panel_mode}
                editing={@editing}
                myself={@myself}
                collapsed={@collapsed}
                metadata={@metadata}
                confirm_delete={@confirm_delete}
                selected_ids={@selected_ids}
              />
              <% end %>
          <% end %>
        <% end %>
      </tbody>
    </table>
    """
  end

  defp editable_group_name(assigns) do
    field_str = to_string(assigns.field)
    editing? = assigns.editing_group == {field_str, assigns.value}
    assigns = assign(assigns, :editing?, editing?)
    assigns = assign(assigns, :field_str, field_str)

    ~H"""
    <%= if @editing? do %>
      <form
        phx-submit="save_group_edit"
        phx-target={@myself}
        class="dt-group-name dt-group-edit-form"
        phx-click={Phoenix.LiveView.JS.dispatch("phx:stop-propagation")}
      >
        <input type="hidden" name="field" value={@field_str} />
        <input type="hidden" name="old_value" value={@value} />
        <input
          type="text"
          name="value"
          value={@value}
          class="dt-cell-input dt-group-edit-input"
          phx-hook="AutoFocus"
          id={"group-edit-#{@field_str}-#{slug(@value)}"}
          phx-blur="save_group_edit"
          phx-target={@myself}
          phx-value-field={@field_str}
          phx-value-old_value={@value}
          phx-keydown="cancel_group_edit"
          phx-target={@myself}
          phx-key="Escape"
        />
      </form>
    <% else %>
      <span
        class="dt-group-name dt-editable-hint"
        phx-click="start_group_edit"
        phx-target={@myself}
        phx-value-group-key={@field_str}
        phx-value-group-value={@value}
      >
        <%= @value %>
      </span>
    <% end %>
    """
  end

  defp collapsed?(collapsed, id), do: Streams.collapsed?(collapsed, id)
  defp more_pages?(streamed, group_id), do: Streams.more_pages?(streamed, group_id)
  defp slug(text), do: Streams.slug_fragment(text)
end
