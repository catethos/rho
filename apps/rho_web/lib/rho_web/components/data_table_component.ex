defmodule RhoWeb.DataTableComponent do
  @moduledoc """
  LiveComponent for an interactive, schema-driven data table.

  Receives a `DataTable.Schema` via the `schema` assign to configure columns,
  grouping, title, and empty state. Owns inline editing, group collapsing,
  and optimistic updates via the signal bus.
  """
  use Phoenix.LiveComponent

  alias RhoWeb.Projections.DataTableProjection

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:editing, fn -> nil end)
      |> assign_new(:collapsed, fn -> MapSet.new() end)
      |> assign_new(:mode_label, fn -> nil end)

    schema = socket.assigns.schema
    table_state = socket.assigns.table_state
    old_rows_map = socket.assigns[:rows_map]

    socket = assign(socket, :mode_label, table_state[:mode_label])

    socket =
      if old_rows_map != table_state.rows_map do
        socket
        |> assign(:rows_map, table_state.rows_map)
        |> assign(:grouped, group_rows(table_state.rows_map, schema.group_by))
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("start_edit", %{"id" => id, "field" => field}, socket) do
    col = find_column(socket.assigns.schema, field)

    if col && col.editable do
      {:noreply, assign(socket, :editing, {id, field})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_edit", %{"row_id" => id, "field" => field, "value" => value}, socket) do
    table_state = socket.assigns.table_state
    client_op_id = generate_op_id()

    {parent_id, child_index} = parse_compound_id(id)

    new_state =
      if child_index do
        DataTableProjection.apply_optimistic_child_edit(
          table_state,
          parent_id,
          child_index,
          String.to_existing_atom(field),
          value,
          socket.assigns.schema.children_key,
          client_op_id
        )
      else
        DataTableProjection.apply_optimistic_edit(
          table_state,
          parent_id,
          String.to_existing_atom(field),
          value,
          client_op_id
        )
      end

    send(self(), {:ws_state_update, :data_table, new_state})

    session_id = socket.assigns.session_id
    publish_user_edit(session_id, id, field, value, client_op_id)

    {:noreply, assign(socket, :editing, nil)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing, nil)}
  end

  def handle_event("toggle_group", %{"group" => group_id}, socket) do
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, group_id),
        do: MapSet.delete(collapsed, group_id),
        else: MapSet.put(collapsed, group_id)

    {:noreply, assign(socket, :collapsed, collapsed)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["dt-panel", @class]}>
      <div class="dt-toolbar">
        <h2 class="dt-title"><%= @schema.title %></h2>
        <span :if={@mode_label} class="dt-mode-label"><%= @mode_label %></span>
        <span class="dt-row-count"><%= map_size(@rows_map) %> rows</span>
        <span :if={@streaming} class="dt-streaming">
          streaming...
        </span>
        <span :if={@total_cost > 0} class="dt-cost">
          $<%= :erlang.float_to_binary(@total_cost / 1, decimals: 4) %>
        </span>
      </div>

      <div class="dt-table-wrap">
        <%= if @grouped == [] do %>
          <div class="dt-empty"><%= @schema.empty_message %></div>
        <% else %>
          <%= for {group_label, children} <- @grouped do %>
            <% group_id = "grp-" <> slug(group_label) %>
            <div id={group_id} class={"dt-group dt-group-l1" <> if(MapSet.member?(@collapsed, group_id), do: " dt-collapsed", else: "")}>
              <div class="dt-group-header dt-group-header-l1" phx-click="toggle_group" phx-target={@myself} phx-value-group={group_id}>
                <span class="dt-chevron"></span>
                <span class="dt-group-name"><%= group_label %></span>
                <span class="dt-group-count"><%= count_nested_rows(children) %> rows</span>
              </div>
              <div class={"dt-group-content" <> if(MapSet.member?(@collapsed, group_id), do: " dt-hidden", else: "")}>
                <%= case children do %>
                  <% {:rows, rows} -> %>
                    <.data_table_rows rows={rows} schema={@schema} editing={@editing} myself={@myself} collapsed={@collapsed} />
                  <% {:nested, sub_groups} -> %>
                    <%= for {sub_label, rows} <- sub_groups do %>
                      <% sub_id = "grp-" <> slug(group_label) <> "-" <> slug(sub_label) %>
                      <div id={sub_id} class={"dt-group dt-group-l2" <> if(MapSet.member?(@collapsed, sub_id), do: " dt-collapsed", else: "")}>
                        <div class="dt-group-header dt-group-header-l2" phx-click="toggle_group" phx-target={@myself} phx-value-group={sub_id}>
                          <span class="dt-chevron"></span>
                          <span class="dt-group-name"><%= sub_label %></span>
                          <span class="dt-group-count"><%= length(rows) %> rows</span>
                        </div>
                        <div class={"dt-group-content" <> if(MapSet.member?(@collapsed, sub_id), do: " dt-hidden", else: "")}>
                          <.data_table_rows rows={rows} schema={@schema} editing={@editing} myself={@myself} collapsed={@collapsed} />
                        </div>
                      </div>
                    <% end %>
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Table rows sub-component ---

  defp data_table_rows(assigns) do
    visible_columns =
      Enum.reject(assigns.schema.columns, fn col -> col.key in assigns.schema.group_by end)

    has_children = assigns.schema.children_key != nil
    child_columns = assigns.schema.child_columns || []
    children_key = assigns.schema.children_key

    assigns =
      assign(assigns,
        visible_columns: visible_columns,
        has_children: has_children,
        child_columns: child_columns,
        children_key: children_key
      )

    ~H"""
    <table class="dt-table">
      <thead>
        <tr>
          <%= if @has_children do %>
            <th class="dt-th dt-th-expand"></th>
          <% end %>
          <th class="dt-th dt-th-id">ID</th>
          <th :for={col <- @visible_columns} class={"dt-th " <> (col.css_class || "dt-th-#{col.key}")}><%= col.label %></th>
          <th :if={@has_children} :for={col <- @child_columns} class={"dt-th " <> (col.css_class || "dt-th-#{col.key}")}><%= col.label %></th>
        </tr>
      </thead>
      <tbody>
        <%= if @has_children do %>
          <%= for row <- @rows do %>
            <% row_id_str = to_string(row.id) %>
            <% expanded = not MapSet.member?(@collapsed, "row-" <> row_id_str) %>
            <% children = Map.get(row, @children_key) || [] %>
            <tr id={"row-#{row.id}"} class="dt-row dt-parent-row">
              <td class="dt-td dt-td-expand" phx-click="toggle_group" phx-target={@myself} phx-value-group={"row-" <> row_id_str}>
                <span class={"dt-chevron" <> if(expanded, do: " dt-expanded", else: "")}></span>
              </td>
              <td class="dt-td dt-td-id"><%= row.id %></td>
              <.editable_cell :for={col <- @visible_columns} row={row} col={col} editing={@editing} myself={@myself} row_id={row_id_str} />
              <td :for={_col <- @child_columns} class="dt-td dt-td-empty"></td>
            </tr>
            <%= if expanded do %>
              <%= for {child, idx} <- Enum.with_index(children) do %>
                <% child_id = row_id_str <> ":child:" <> to_string(idx) %>
                <% child_map = atomize_child(child) %>
                <tr id={"row-#{child_id}"} class="dt-row dt-child-row">
                  <td class="dt-td dt-td-expand"></td>
                  <td class="dt-td dt-td-id dt-child-id"><%= idx + 1 %></td>
                  <td :for={_col <- @visible_columns} class="dt-td dt-td-empty"></td>
                  <.editable_cell :for={col <- @child_columns} row={child_map} col={col} editing={@editing} myself={@myself} row_id={child_id} />
                </tr>
              <% end %>
            <% end %>
          <% end %>
        <% else %>
          <tr :for={row <- @rows} id={"row-#{row.id}"} class="dt-row">
            <td class="dt-td dt-td-id"><%= row.id %></td>
            <.editable_cell :for={col <- @visible_columns} row={row} col={col} editing={@editing} myself={@myself} row_id={to_string(row.id)} />
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end

  # --- editable_cell component ---

  defp editable_cell(assigns) do
    row_id = assigns.row_id
    editing? = assigns.editing == {row_id, Atom.to_string(assigns.col.key)}
    value = Map.get(assigns.row, assigns.col.key, "")

    assigns = assign(assigns, editing?: editing?, value: value, cell_row_id: row_id)

    ~H"""
    <td
      class={"dt-td " <> (@col.css_class || "dt-td-#{@col.key}")}
      phx-click={if @col.editable, do: "start_edit"}
      phx-target={@myself}
      phx-value-id={@cell_row_id}
      phx-value-field={@col.key}
    >
      <%= if @editing? do %>
        <form phx-submit="save_edit" phx-target={@myself} phx-click-away="cancel_edit">
          <input type="hidden" name="row_id" value={@cell_row_id} />
          <input type="hidden" name="field" value={@col.key} />
          <%= if @col.type == :textarea do %>
            <textarea
              name="value"
              class="dt-cell-input"
              phx-hook="AutoFocus"
              id={"edit-#{@cell_row_id}-#{@col.key}"}
              phx-keydown="cancel_edit"
              phx-target={@myself}
              phx-key="Escape"
            ><%= @value %></textarea>
          <% else %>
            <input
              type={if @col.type == :number, do: "number", else: "text"}
              name="value"
              value={@value}
              class="dt-cell-input"
              phx-hook="AutoFocus"
              id={"edit-#{@cell_row_id}-#{@col.key}"}
              phx-blur="save_edit"
              phx-target={@myself}
              phx-value-id={@cell_row_id}
              phx-value-field={@col.key}
              phx-keydown="cancel_edit"
              phx-target={@myself}
              phx-key="Escape"
            />
          <% end %>
        </form>
      <% else %>
        <span class="dt-cell-text"><%= @value %></span>
      <% end %>
    </td>
    """
  end

  # --- Grouping helpers ---

  defp group_rows(rows_map, _group_by) when map_size(rows_map) == 0, do: []

  defp group_rows(rows_map, []) do
    rows = rows_map |> Map.values() |> Enum.sort_by(& &1[:sort_order])
    [{"All", {:rows, rows}}]
  end

  defp group_rows(rows_map, [field]) do
    rows_map
    |> Map.values()
    |> Enum.sort_by(& &1[:sort_order])
    |> group_preserving_order(field)
    |> Enum.map(fn {label, rows} -> {label, {:rows, rows}} end)
  end

  defp group_rows(rows_map, [field1, field2 | _]) do
    rows_map
    |> Map.values()
    |> Enum.sort_by(& &1[:sort_order])
    |> group_preserving_order(field1)
    |> Enum.map(fn {label, rows} ->
      sub_groups = group_preserving_order(rows, field2)
      {label, {:nested, sub_groups}}
    end)
  end

  defp group_preserving_order(rows, field) do
    {groups, order} =
      Enum.reduce(rows, {%{}, %{}}, fn row, {groups, order} ->
        key = Map.get(row, field, "") |> to_string()
        groups = Map.update(groups, key, [row], &[row | &1])
        order = Map.put_new(order, key, map_size(order))
        {groups, order}
      end)

    order
    |> Enum.sort_by(fn {_key, idx} -> idx end)
    |> Enum.map(fn {key, _} -> {key, Enum.reverse(Map.get(groups, key, []))} end)
  end

  defp count_nested_rows({:rows, rows}), do: length(rows)

  defp count_nested_rows({:nested, sub_groups}) do
    Enum.reduce(sub_groups, 0, fn {_label, rows}, acc -> acc + length(rows) end)
  end

  defp find_column(schema, field_name) when is_binary(field_name) do
    key = String.to_existing_atom(field_name)

    Enum.find(schema.columns, &(&1.key == key)) ||
      Enum.find(schema.child_columns || [], &(&1.key == key))
  rescue
    ArgumentError -> nil
  end

  defp slug(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp slug(_), do: "unknown"

  defp parse_compound_id(id) when is_binary(id) do
    case String.split(id, ":child:") do
      [parent, child_idx] ->
        {parse_row_id(parent), String.to_integer(child_idx)}

      [_single] ->
        {parse_row_id(id), nil}
    end
  end

  defp parse_row_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp parse_row_id(id), do: id

  defp atomize_child(child) when is_map(child) do
    Map.new(child, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> child
  end

  defp generate_op_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end

  defp publish_user_edit(session_id, row_id, field, value, client_op_id) do
    topic = "rho.session.#{session_id}.events.data_table_user_edit"

    Rho.Comms.publish(
      topic,
      %{
        session_id: session_id,
        row_id: row_id,
        field: field,
        value: value,
        client_op_id: client_op_id
      },
      source: "/session/#{session_id}/user"
    )
  end
end
