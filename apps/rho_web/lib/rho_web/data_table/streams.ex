defmodule RhoWeb.DataTable.Streams do
  @moduledoc """
  LiveView stream helpers for `RhoWeb.DataTableComponent`.

  Stream names must be atoms, while group ids come from runtime row data. This
  module owns the fixed atom pool and the row/window metadata used to keep
  large grouped tables lazy.
  """

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [
      stream: 3,
      stream: 4,
      stream_configure: 3,
      stream_delete: 3,
      stream_insert: 3
    ]

  @stream_pool_size 2048
  @stream_pool for(i <- 0..(@stream_pool_size - 1), do: :"_dt_rows_#{i}")
               |> List.to_tuple()

  @default_page_size 200

  @doc "Default page size for grouped stream pagination."
  def default_page_size, do: @default_page_size

  @doc "Returns whether a group id has stream metadata."
  def group_streamed?(streamed, group_id) do
    case Map.fetch(streamed, group_id) do
      {:ok, _} -> true
      :error -> false
    end
  end

  @doc "Returns whether a collapsed-state value hides the given id."
  def collapsed?(:all_collapsed, _id), do: true
  def collapsed?(set, id), do: MapSet.member?(set, id)

  @doc "Returns whether a streamed group has more rows to page in."
  def more_pages?(streamed, group_id) do
    case streamed && Map.get(streamed, group_id) do
      %{loaded: loaded, total: total} when loaded < total -> true
      _ -> false
    end
  end

  @doc "Builds a deterministic group id for one grouping level."
  def group_id_for(category) do
    "grp-" <> slug_fragment(category)
  end

  @doc "Builds a deterministic group id for two grouping levels."
  def group_id_for(category, cluster) do
    "grp-" <> slug_fragment(category) <> "-" <> slug_fragment(cluster)
  end

  @doc "Slug fragment used by group ids and DOM ids."
  def slug_fragment(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  def slug_fragment(_), do: "unknown"

  @doc """
  Seeds a single leaf group's stream with the first `page_size` rows.

  Returns `{socket, meta}` where `meta` is stored under `:_streamed_groups`.
  """
  def seed_group_stream(socket, group_id, rows, panel_mode, collapsed, page_size, sort_key) do
    {socket, stream_name} = stream_name_for_group(socket, group_id)
    socket = ensure_stream_configured(socket, stream_name)

    total = length(rows)
    first_window = Enum.take(rows, page_size)
    items = build_stream_items(first_window, panel_mode, collapsed)

    socket = stream(socket, stream_name, items, reset: true)

    meta = %{total: total, loaded: length(first_window), sort: sort_key}
    streamed = Map.put(socket.assigns[:_streamed_groups] || %{}, group_id, meta)
    socket = assign(socket, :_streamed_groups, streamed)

    {socket, meta}
  end

  @doc "Appends the next page of rows for a stream-backed group."
  def append_group_page(
        socket,
        group_id,
        rows,
        panel_mode,
        collapsed,
        loaded,
        page_size,
        sort_key
      ) do
    next_window = Enum.slice(rows, loaded, page_size)
    items = build_stream_items(next_window, panel_mode, collapsed)

    {socket, stream_name} = stream_name_for_group(socket, group_id)
    socket = ensure_stream_configured(socket, stream_name)
    socket = stream(socket, stream_name, items)

    meta = %{
      total: length(rows),
      loaded: loaded + length(next_window),
      sort: sort_key
    }

    streamed = Map.put(socket.assigns[:_streamed_groups] || %{}, group_id, meta)
    {assign(socket, :_streamed_groups, streamed), meta}
  end

  @doc "Builds stream items, including panel rows when panel mode is expanded."
  def build_stream_items(stream_rows, false, _collapsed) do
    Enum.map(stream_rows, fn row -> Map.put(row, :_kind, :parent) end)
  end

  def build_stream_items(stream_rows, true, collapsed) do
    Enum.flat_map(stream_rows, fn row ->
      row_id_str = to_string(row_id(row))
      parent = Map.put(row, :_kind, :parent)

      if collapsed?(collapsed, "row-" <> row_id_str) do
        [parent]
      else
        [parent, Map.put(row, :_kind, :panel)]
      end
    end)
  end

  @doc "Resolves a group id to a stable stream atom from the fixed pool."
  def stream_name_for_group(socket, group_id) do
    mapping = socket.assigns[:_group_to_stream] || %{}

    case Map.get(mapping, group_id) do
      nil ->
        idx = map_size(mapping)

        if idx >= @stream_pool_size do
          raise "DataTableComponent stream pool exhausted (#{@stream_pool_size} groups). " <>
                  "Either increase @stream_pool_size or split this view."
        end

        atom = elem(@stream_pool, idx)
        {assign(socket, :_group_to_stream, Map.put(mapping, group_id, atom)), atom}

      atom ->
        {socket, atom}
    end
  end

  @doc "Finds the rows belonging to a group id in the grouped tree."
  def lookup_group_rows(grouped, target_group_id) do
    Enum.reduce_while(grouped, [], fn {label, children}, _acc ->
      case children do
        {:rows, rows} ->
          if group_id_for(label) == target_group_id do
            {:halt, rows}
          else
            {:cont, []}
          end

        {:nested, sub_groups} ->
          found =
            Enum.reduce_while(sub_groups, [], fn {sub_label, rows}, _sub_acc ->
              if group_id_for(label, sub_label) == target_group_id do
                {:halt, rows}
              else
                {:cont, []}
              end
            end)

          case found do
            [] -> {:cont, []}
            rows -> {:halt, rows}
          end
      end
    end)
  end

  @doc "Returns the stream name that owns the row's current group, if any."
  def stream_for_row(socket, row) do
    cat = Rho.MapAccess.get(row, :category)
    clu = Rho.MapAccess.get(row, :cluster)

    group_id =
      cond do
        cat && clu -> group_id_for(cat, clu)
        cat -> group_id_for(cat)
        true -> nil
      end

    mapping = socket.assigns[:_group_to_stream] || %{}

    case group_id && Map.get(mapping, group_id) do
      nil -> :none
      stream_name -> {:ok, stream_name}
    end
  end

  @doc "Inserts/replaces a row in its owning stream."
  def stream_insert_row(socket, stream_name, row) do
    stream_insert(socket, stream_name, row)
  end

  @doc "Deletes parent and panel stream items for a row."
  def stream_delete_row(socket, stream_name, row) do
    socket
    |> stream_delete(stream_name, Map.put(row, :_kind, :parent))
    |> stream_delete(stream_name, Map.put(row, :_kind, :panel))
  end

  defp ensure_stream_configured(socket, stream_name) do
    configured = socket.assigns[:_streams_configured] || MapSet.new()

    if MapSet.member?(configured, stream_name) do
      socket
    else
      socket
      |> stream_configure(stream_name, dom_id: &row_dom_id/1)
      |> assign(:_streams_configured, MapSet.put(configured, stream_name))
    end
  end

  defp row_dom_id(%{_kind: :panel} = row), do: "panel-" <> to_string(row_id(row))
  defp row_dom_id(row), do: "row-" <> to_string(row_id(row))

  defp row_id(row) do
    Rho.MapAccess.get(row, :id)
  end
end
