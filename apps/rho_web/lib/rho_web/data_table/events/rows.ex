defmodule RhoWeb.DataTable.Events.Rows do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Rho.Stdlib.DataTable
  alias RhoWeb.DataTable.Commands
  alias RhoWeb.DataTable.Rows
  alias RhoWeb.DataTable.StreamLifecycle

  def handle_event("start_edit", %{"id" => id, "field" => field}, socket) do
    col = find_column(socket.assigns.schema, field)

    if col && col.editable do
      {parent_id, child_index} = parse_compound_id(id)

      socket =
        socket
        |> assign(:editing, {id, field})
        |> StreamLifecycle.optimistic_stream_update(parent_id, child_index)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_edit", %{"row_id" => id, "field" => field, "value" => value}, socket) do
    session_id = socket.assigns.session_id
    active_table = socket.assigns[:active_table] || "main"

    {parent_id, child_index} = parse_compound_id(id)

    {change, optimistic_key} =
      Commands.cell_change(socket.assigns.rows, socket.assigns.schema, id, field, value)

    optimistic = Map.put(socket.assigns.optimistic_edits, optimistic_key, value)

    socket =
      socket
      |> assign(:optimistic_edits, optimistic)
      |> assign(:editing, nil)
      |> StreamLifecycle.optimistic_stream_update(parent_id, child_index)

    case DataTable.update_cells(session_id, [change], table: active_table) do
      :ok ->
        send(self(), {:data_table_refresh, active_table})
        {:noreply, socket}

      {:error, reason} ->
        send(self(), {:data_table_error, reason})
        {:noreply, socket}
    end
  end

  def handle_event("resolve_conflict", %{"id" => id, "resolution" => resolution}, socket) do
    session_id = socket.assigns.session_id
    active_table = socket.assigns[:active_table] || "combine_preview"

    {change, optimistic_key} = Commands.conflict_resolution_change(id, resolution)
    optimistic = Map.put(socket.assigns.optimistic_edits, optimistic_key, resolution)

    socket =
      socket
      |> assign(:optimistic_edits, optimistic)
      |> StreamLifecycle.optimistic_stream_update(id)

    case DataTable.update_cells(session_id, [change], table: active_table) do
      :ok ->
        send(self(), {:data_table_refresh, active_table})
        {:noreply, socket}

      {:error, reason} ->
        send(self(), {:data_table_error, reason})
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {parent_id, child_index} =
      case socket.assigns.editing do
        {id, _field} -> parse_compound_id(id)
        _ -> {nil, nil}
      end

    socket = assign(socket, :editing, nil)

    socket =
      if parent_id,
        do: StreamLifecycle.optimistic_stream_update(socket, parent_id, child_index),
        else: socket

    {:noreply, socket}
  end

  def handle_event("toggle_group", %{"group" => group_id}, socket) do
    {:noreply, StreamLifecycle.toggle_group(socket, group_id)}
  end

  def handle_event("load_more_in_group", %{"group" => group_id}, socket) do
    {:noreply, StreamLifecycle.append_group_page(socket, group_id)}
  end

  def handle_event("start_group_edit", %{"group-key" => key, "group-value" => value}, socket) do
    {:noreply, assign(socket, :editing_group, {key, value})}
  end

  def handle_event("cancel_group_edit", _params, socket) do
    {:noreply, assign(socket, :editing_group, nil)}
  end

  def handle_event(
        "save_group_edit",
        %{"field" => field, "old_value" => old_value, "value" => new_value},
        socket
      ) do
    if new_value == "" or new_value == old_value do
      {:noreply, assign(socket, :editing_group, nil)}
    else
      session_id = socket.assigns.session_id
      active_table = socket.assigns[:active_table] || "main"

      changes = Commands.group_edit_changes(socket.assigns.rows, field, old_value, new_value)
      socket = assign(socket, :editing_group, nil)

      case changes do
        [] ->
          {:noreply, socket}

        _ ->
          case DataTable.update_cells(session_id, changes, table: active_table) do
            :ok ->
              send(self(), {:data_table_refresh, active_table})
              {:noreply, socket}

            {:error, reason} ->
              send(self(), {:data_table_error, reason})
              {:noreply, socket}
          end
      end
    end
  end

  def handle_event("add_row", params, socket) do
    session_id = socket.assigns.session_id
    active_table = socket.assigns[:active_table] || "main"
    row = Commands.new_row(socket.assigns.schema, params)

    case DataTable.add_rows(session_id, [row], table: active_table) do
      {:ok, _inserted} ->
        send(self(), {:data_table_refresh, active_table})
        {:noreply, socket}

      {:error, reason} ->
        send(self(), {:data_table_error, reason})
        {:noreply, socket}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirm_delete, id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  def handle_event("delete_row", %{"id" => id}, socket) do
    session_id = socket.assigns.session_id
    active_table = socket.assigns[:active_table] || "main"

    case DataTable.delete_rows(session_id, [id], table: active_table) do
      :ok ->
        socket =
          socket
          |> StreamLifecycle.optimistic_stream_delete(id)
          |> assign(:confirm_delete, nil)

        send(self(), {:data_table_refresh, active_table})
        {:noreply, socket}

      {:error, reason} ->
        send(self(), {:data_table_error, reason})
        {:noreply, assign(socket, :confirm_delete, nil)}
    end
  end

  def handle_event("add_child", %{"parent-id" => parent_id}, socket) do
    session_id = socket.assigns.session_id
    active_table = socket.assigns[:active_table] || "main"
    change = Commands.add_child_change(socket.assigns.rows, socket.assigns.schema, parent_id)

    case DataTable.update_cells(session_id, [change], table: active_table) do
      :ok ->
        send(self(), {:data_table_refresh, active_table})
        {:noreply, socket}

      {:error, reason} ->
        send(self(), {:data_table_error, reason})
        {:noreply, socket}
    end
  end

  def handle_event("delete_child", %{"parent-id" => parent_id, "index" => idx_str}, socket) do
    session_id = socket.assigns.session_id
    active_table = socket.assigns[:active_table] || "main"

    change =
      Commands.delete_child_change(socket.assigns.rows, socket.assigns.schema, parent_id, idx_str)

    case DataTable.update_cells(session_id, [change], table: active_table) do
      :ok ->
        send(self(), {:data_table_refresh, active_table})
        {:noreply, socket}

      {:error, reason} ->
        send(self(), {:data_table_error, reason})
        {:noreply, socket}
    end
  end

  def handle_event("sort_column", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)

    {new_sort_by, new_sort_dir} =
      case {socket.assigns.sort_by, socket.assigns.sort_dir} do
        {^field_atom, :asc} -> {field_atom, :desc}
        {^field_atom, :desc} -> {nil, :asc}
        _ -> {field_atom, :asc}
      end

    rows = socket.assigns.rows
    sorted = Rows.sort(rows, new_sort_by, new_sort_dir)
    grouped = Rows.group(sorted, socket.assigns.schema.group_by)

    socket =
      socket
      |> assign(:sort_by, new_sort_by)
      |> assign(:sort_dir, new_sort_dir)
      |> assign(:grouped, grouped)

    {:noreply, StreamLifecycle.reset_populated_streams(socket, grouped)}
  end

  defp find_column(schema, field_name) when is_binary(field_name) do
    Enum.find(schema.columns, &(Atom.to_string(&1.key) == field_name)) ||
      Enum.find(schema.child_columns || [], &(Atom.to_string(&1.key) == field_name))
  end

  defp find_column(_, _), do: nil

  defp parse_compound_id(id) when is_binary(id) do
    case String.split(id, ":child:") do
      [parent, child_idx] ->
        case Integer.parse(child_idx) do
          {n, ""} -> {parent, n}
          _ -> {id, nil}
        end

      [_single] ->
        {id, nil}
    end
  end

  defp parse_compound_id(id), do: {to_string(id), nil}
end
