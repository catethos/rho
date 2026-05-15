defmodule RhoWeb.DataTable.StreamLifecycle do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias RhoWeb.DataTable.Optimistic
  alias RhoWeb.DataTable.Rows
  alias RhoWeb.DataTable.Streams

  def apply_expand_groups(assigns, collapsed, grouped, socket) do
    case Map.get(assigns, :expand_groups) do
      nil ->
        {collapsed, socket}

      [] ->
        {collapsed, socket}

      groups when is_list(groups) ->
        base =
          case collapsed do
            :all_collapsed -> Rows.collect_group_ids(grouped)
            set -> set
          end

        new_collapsed =
          Enum.reduce(groups, base, fn {category, cluster}, acc ->
            acc
            |> MapSet.delete(group_id_for(category))
            |> then(fn set ->
              if cluster, do: MapSet.delete(set, group_id_for(category, cluster)), else: set
            end)
          end)

        {new_collapsed, assign(socket, :expand_groups, nil)}
    end
  end

  def seed_visible_streams(socket, grouped, schema, collapsed, expand_hint, rows_changed?) do
    panel_mode = Map.get(schema, :children_display, :rows) == :panel
    streamed = socket.assigns[:_streamed_groups] || %{}
    page_size = socket.assigns[:stream_page_size] || Streams.default_page_size()
    sort_key = {socket.assigns.sort_by, socket.assigns.sort_dir}

    hinted = expand_hint_to_group_ids(expand_hint)

    walk_leaf_groups(grouped, socket, fn group_id, rows, acc ->
      cond do
        group_streamed?(streamed, group_id) and rows_changed? ->
          {next_socket, _meta} =
            Streams.seed_group_stream(
              acc,
              group_id,
              rows,
              panel_mode,
              collapsed,
              page_size,
              sort_key
            )

          next_socket

        MapSet.member?(hinted, group_id) and not collapsed?(collapsed, group_id) ->
          {next_socket, _meta} =
            Streams.seed_group_stream(
              acc,
              group_id,
              rows,
              panel_mode,
              collapsed,
              page_size,
              sort_key
            )

          next_socket

        true ->
          acc
      end
    end)
  end

  def expand_groups_hint(assigns) do
    case Map.get(assigns, :expand_groups) do
      nil -> []
      [] -> []
      list when is_list(list) -> list
    end
  end

  def toggle_group(socket, group_id) do
    collapsed =
      case socket.assigns.collapsed do
        :all_collapsed ->
          Rows.collect_group_ids(socket.assigns.grouped) |> MapSet.delete(group_id)

        set ->
          if MapSet.member?(set, group_id),
            do: MapSet.delete(set, group_id),
            else: MapSet.put(set, group_id)
      end

    was_collapsed? =
      case socket.assigns.collapsed do
        :all_collapsed -> true
        set -> MapSet.member?(set, group_id)
      end

    becoming_visible? = was_collapsed? and not collapsed?(collapsed, group_id)
    socket = assign(socket, :collapsed, collapsed)

    case parse_row_toggle(group_id, socket.assigns.rows) do
      {:row, row, parent_group_id} ->
        toggle_panel_in_stream(socket, row, parent_group_id, collapsed)

      :group ->
        if becoming_visible? do
          populate_group_on_expand(socket, group_id, collapsed)
        else
          socket
        end
    end
  end

  def append_group_page(socket, group_id) do
    streamed = socket.assigns[:_streamed_groups] || %{}

    case Map.get(streamed, group_id) do
      nil ->
        socket

      %{loaded: loaded, total: total} when loaded >= total ->
        socket

      %{loaded: loaded, total: _total} ->
        page_size = socket.assigns[:stream_page_size] || Streams.default_page_size()
        schema = socket.assigns.schema
        panel_mode = Map.get(schema, :children_display, :rows) == :panel
        collapsed = socket.assigns.collapsed
        rows = Streams.lookup_group_rows(socket.assigns.grouped, group_id)

        {socket, _meta} =
          Streams.append_group_page(
            socket,
            group_id,
            rows,
            panel_mode,
            collapsed,
            loaded,
            page_size,
            {socket.assigns.sort_by, socket.assigns.sort_dir}
          )

        socket
    end
  end

  def reset_populated_streams(socket, grouped) do
    streamed = socket.assigns[:_streamed_groups] || %{}
    schema = socket.assigns.schema
    panel_mode = Map.get(schema, :children_display, :rows) == :panel
    page_size = socket.assigns[:stream_page_size] || Streams.default_page_size()
    collapsed = socket.assigns.collapsed
    sort_key = {socket.assigns.sort_by, socket.assigns.sort_dir}

    Enum.reduce(streamed, socket, fn {group_id, _meta}, acc ->
      rows = Streams.lookup_group_rows(grouped, group_id)

      {new_acc, _meta} =
        Streams.seed_group_stream(acc, group_id, rows, panel_mode, collapsed, page_size, sort_key)

      new_acc
    end)
  end

  def optimistic_stream_update(socket, parent_id, child_index \\ nil) do
    rows = socket.assigns[:rows] || []

    case find_row(rows, to_string(parent_id)) do
      nil ->
        socket

      row ->
        updated_base =
          Optimistic.apply_row(row, to_string(parent_id), socket.assigns.optimistic_edits)

        updated_parent = Map.put(updated_base, :_kind, :parent)

        case Streams.stream_for_row(socket, updated_parent) do
          {:ok, stream_name} ->
            socket = Streams.stream_insert_row(socket, stream_name, updated_parent)

            if child_index != nil do
              Streams.stream_insert_row(
                socket,
                stream_name,
                Map.put(updated_base, :_kind, :panel)
              )
            else
              socket
            end

          :none ->
            socket
        end
    end
  end

  def optimistic_stream_delete(socket, id) do
    rows = socket.assigns[:rows] || []

    case find_row(rows, to_string(id)) do
      nil ->
        socket

      row ->
        case Streams.stream_for_row(socket, row) do
          {:ok, stream_name} ->
            Streams.stream_delete_row(socket, stream_name, row)

          :none ->
            socket
        end
    end
  end

  defp expand_hint_to_group_ids(expand_hint) do
    Enum.reduce(expand_hint, MapSet.new(), fn
      {category, nil}, acc ->
        MapSet.put(acc, group_id_for(category))

      {category, cluster}, acc ->
        acc
        |> MapSet.put(group_id_for(category))
        |> MapSet.put(group_id_for(category, cluster))

      _, acc ->
        acc
    end)
  end

  defp group_streamed?(streamed, group_id), do: Streams.group_streamed?(streamed, group_id)

  defp walk_leaf_groups(grouped, socket, fun) do
    Enum.reduce(grouped, socket, fn {label, children}, acc ->
      case children do
        {:rows, rows} ->
          fun.(group_id_for(label), rows, acc)

        {:nested, sub_groups} ->
          Enum.reduce(sub_groups, acc, fn {sub_label, rows}, inner ->
            fun.(group_id_for(label, sub_label), rows, inner)
          end)
      end
    end)
  end

  defp populate_group_on_expand(socket, group_id, collapsed) do
    streamed = socket.assigns[:_streamed_groups] || %{}

    if group_streamed?(streamed, group_id) do
      socket
    else
      schema = socket.assigns.schema
      panel_mode = Map.get(schema, :children_display, :rows) == :panel
      page_size = socket.assigns[:stream_page_size] || Streams.default_page_size()
      sort_key = {socket.assigns.sort_by, socket.assigns.sort_dir}
      rows = Streams.lookup_group_rows(socket.assigns.grouped, group_id)

      {socket, _meta} =
        Streams.seed_group_stream(
          socket,
          group_id,
          rows,
          panel_mode,
          collapsed,
          page_size,
          sort_key
        )

      socket
    end
  end

  defp parse_row_toggle("row-" <> row_id_str, rows) when is_list(rows) do
    case find_row(rows, row_id_str) do
      nil ->
        :group

      row ->
        cat = Rho.MapAccess.get(row, :category)
        clu = Rho.MapAccess.get(row, :cluster)

        parent_group_id =
          cond do
            cat && clu -> group_id_for(cat, clu)
            cat -> group_id_for(cat)
            true -> nil
          end

        if parent_group_id, do: {:row, row, parent_group_id}, else: :group
    end
  end

  defp parse_row_toggle(_, _), do: :group

  defp toggle_panel_in_stream(socket, _row, parent_group_id, collapsed) do
    schema = socket.assigns.schema
    panel_mode = Map.get(schema, :children_display, :rows) == :panel
    streamed = socket.assigns[:_streamed_groups] || %{}

    cond do
      not panel_mode ->
        socket

      not group_streamed?(streamed, parent_group_id) ->
        socket

      true ->
        page_size = socket.assigns[:stream_page_size] || Streams.default_page_size()
        sort_key = {socket.assigns.sort_by, socket.assigns.sort_dir}
        rows = Streams.lookup_group_rows(socket.assigns.grouped, parent_group_id)

        {socket, _meta} =
          Streams.seed_group_stream(
            socket,
            parent_group_id,
            rows,
            panel_mode,
            collapsed,
            page_size,
            sort_key
          )

        socket
    end
  end

  defp find_row(row_entries, id) do
    Enum.find(row_entries, fn row -> to_string(Rows.row_id(row)) == id end)
  end

  defp collapsed?(collapsed, id), do: Streams.collapsed?(collapsed, id)
  defp group_id_for(category), do: Streams.group_id_for(category)
  defp group_id_for(category, cluster), do: Streams.group_id_for(category, cluster)
end
