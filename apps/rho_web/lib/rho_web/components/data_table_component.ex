defmodule RhoWeb.DataTableComponent do
  @moduledoc """
  LiveComponent for an interactive, schema-driven data table.

  Pure renderer that takes an ordered row list from a server snapshot
  plus a `RhoWeb.DataTable.Schema` to configure columns, grouping,
  title, and empty state. All row state is owned by
  `Rho.Stdlib.DataTable.Server`; this component reads rows via assigns
  and writes cell edits back through the client API synchronously. The
  parent LiveView is responsible for refetching snapshots on
  invalidation events and pushing them back into this component via
  `ws_state_update`.

  ## Tab strip

  If `tables` / `table_order` are passed, a tab strip is rendered
  above the table so the user can switch the active named table.
  Clicking a tab sends `{:data_table_switch_tab, name}` to the parent
  LiveView.
  """
  use Phoenix.LiveComponent

  alias Rho.Stdlib.DataTable
  alias Rho.Stdlib.DataTable.WorkbenchContext
  alias RhoWeb.WorkbenchPresenter

  # Compile-time pool of atoms used as Phoenix LiveView stream names.
  # Stream names must be atoms (Phoenix LiveView API), but group ids are
  # derived at runtime from user-controlled (category, cluster) strings,
  # so we cannot mint atoms dynamically (atom-table DoS). At runtime we
  # assign each unique group id a stable index and look the name up
  # here in O(1).
  @stream_pool_size 2048
  @stream_pool for(i <- 0..(@stream_pool_size - 1), do: :"_dt_rows_#{i}")
               |> List.to_tuple()

  # Default page size for lazy stream population. The first expand of a
  # group seeds at most this many rows; the rest stream in via
  # `phx-viewport-bottom` (Phase C).
  @default_stream_page_size 200

  @impl true
  def mount(socket) do
    socket =
      socket
      |> assign(:_streams_configured, MapSet.new())
      |> assign(:_streamed_groups, %{})
      |> assign(:_group_to_stream, %{})

    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:editing, fn -> nil end)
      |> assign_new(:collapsed, fn -> :all_collapsed end)
      |> assign_new(:optimistic_edits, fn -> %{} end)
      |> assign_new(:metadata, fn -> %{} end)
      |> assign_new(:workbench_context, fn -> nil end)
      |> assign_new(:sort_by, fn -> nil end)
      |> assign_new(:sort_dir, fn -> :asc end)
      |> assign_new(:confirm_delete, fn -> nil end)
      |> assign_new(:editing_group, fn -> nil end)
      |> assign_new(:view_key, fn -> nil end)
      |> assign_new(:flash_message, fn -> nil end)
      |> assign_new(:action_dialog, fn -> nil end)
      |> assign_new(:export_menu_open, fn -> false end)
      |> assign_new(:selected_ids, fn -> MapSet.new() end)
      |> assign_new(:_streams_configured, fn -> MapSet.new() end)
      |> assign_new(:_streamed_groups, fn -> %{} end)
      |> assign_new(:_group_to_stream, fn -> %{} end)
      |> assign_new(:stream_page_size, fn -> @default_stream_page_size end)

    rows = socket.assigns[:rows] || []
    schema = socket.assigns.schema
    version = socket.assigns[:version]
    last_version = socket.assigns[:_last_version]

    # Clear optimistic edits whenever a newer snapshot arrives, since the
    # server's version is now authoritative.
    optimistic =
      if version && last_version && version > last_version do
        %{}
      else
        socket.assigns.optimistic_edits
      end

    effective_rows = apply_optimistic(rows, optimistic)
    sorted_rows = sort_rows(effective_rows, socket.assigns.sort_by, socket.assigns.sort_dir)
    grouped = group_rows(sorted_rows, schema.group_by)

    # On first render (or first render with data), collapse all groups.
    collapsed =
      case socket.assigns.collapsed do
        :all_collapsed ->
          ids = collect_all_group_ids(grouped)
          # If no groups yet, stay sentinel so we catch the first real data
          if MapSet.size(ids) == 0, do: :all_collapsed, else: ids

        other ->
          other
      end

    # `expand_groups` is a transient hint pushed by the parent LV
    # (via send_update) when an external action — e.g. Suggest — added
    # rows the user needs to see. Each entry is a `{category, cluster
    # | nil}` tuple. We materialize the collapsed set if needed and
    # drop the matching group ids from it.
    {collapsed, socket} =
      case Map.get(assigns, :expand_groups) do
        nil ->
          {collapsed, socket}

        [] ->
          {collapsed, socket}

        groups when is_list(groups) ->
          base =
            case collapsed do
              :all_collapsed -> collect_all_group_ids(grouped)
              set -> set
            end

          new_collapsed =
            Enum.reduce(groups, base, fn {category, cluster}, acc ->
              acc
              |> MapSet.delete(group_id_for(category))
              |> then(fn s ->
                if cluster, do: MapSet.delete(s, group_id_for(category, cluster)), else: s
              end)
            end)

          # Clear the hint so it doesn't reapply on every re-render.
          {new_collapsed, assign(socket, :expand_groups, nil)}
      end

    select_all_state = compute_select_all_state(effective_rows, socket.assigns[:selected_ids])

    socket =
      socket
      |> assign(:rows, effective_rows)
      |> assign(:_last_version, version)
      |> assign(:optimistic_edits, optimistic)
      |> assign(:collapsed, collapsed)
      |> assign(:grouped, grouped)
      |> assign(:select_all_state, select_all_state)

    # Phase B/D: lazy + version-gated stream refresh.
    #
    # Eagerly seed only the groups that are *currently expanded* —
    # collapsed groups contribute zero rows to the LV state and zero
    # DOM nodes. Already-streamed groups are refreshed only when the
    # snapshot version bumps (`version > last_version`), keeping
    # repeat re-renders cheap.
    rows_changed? = version != nil and (last_version == nil or version > last_version)

    socket =
      seed_visible_streams(
        socket,
        grouped,
        schema,
        collapsed,
        expand_groups_hint(assigns),
        rows_changed?
      )

    {:ok, socket}
  end

  # --- Stream seeding ---

  # Returns the optional `expand_groups` hint as a list (or []) so we
  # can eagerly seed groups the parent LV asked us to surface — e.g.
  # after a Suggest run added rows the user needs to see immediately.
  defp expand_groups_hint(assigns) do
    case Map.get(assigns, :expand_groups) do
      nil -> []
      [] -> []
      list when is_list(list) -> list
    end
  end

  defp seed_visible_streams(socket, grouped, schema, collapsed, expand_hint, rows_changed?) do
    panel_mode = Map.get(schema, :children_display, :rows) == :panel
    streamed = socket.assigns[:_streamed_groups] || %{}
    page_size = socket.assigns[:stream_page_size] || @default_stream_page_size
    sort_key = {socket.assigns.sort_by, socket.assigns.sort_dir}

    hinted = expand_hint_to_group_ids(expand_hint)

    walk_leaf_groups(grouped, socket, fn group_id, rows, acc ->
      cond do
        group_streamed?(streamed, group_id) and rows_changed? ->
          # Already streamed and snapshot version bumped → refresh to
          # first window in the current sort.
          {next_socket, _meta} =
            seed_group_stream(acc, group_id, rows, panel_mode, collapsed, page_size, sort_key)

          next_socket

        MapSet.member?(hinted, group_id) and not collapsed?(collapsed, group_id) ->
          # Hinted-and-now-expanded → seed eagerly so the user sees the
          # rows on first render after the hint fires.
          {next_socket, _meta} =
            seed_group_stream(acc, group_id, rows, panel_mode, collapsed, page_size, sort_key)

          next_socket

        true ->
          acc
      end
    end)
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

  defp group_streamed?(streamed, group_id) do
    case Map.fetch(streamed, group_id) do
      {:ok, _} -> true
      :error -> false
    end
  end

  # Visits every leaf group, threading `socket` through `fun.(group_id,
  # rows, socket)`. Returns the final socket.
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

  # Seeds a single leaf group's stream with the first `page_size` rows
  # in the current sort order. Updates `:_streamed_groups` metadata.
  # Returns `{socket, meta}`.
  defp seed_group_stream(socket, group_id, rows, panel_mode, collapsed, page_size, sort_key) do
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

  defp build_stream_items(stream_rows, false, _collapsed) do
    Enum.map(stream_rows, fn row -> Map.put(row, :_kind, :parent) end)
  end

  defp build_stream_items(stream_rows, true, collapsed) do
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

  # Resolves a group_id (a runtime string built from user data) to a
  # stable stream-name atom drawn from the precompiled pool. Returns
  # `{socket, atom}`; the socket carries the (possibly extended)
  # group_id → atom mapping.
  defp stream_name_for_group(socket, group_id) do
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

  defp row_dom_id(%{_kind: :panel} = row), do: "panel-" <> to_string(row_id(row))
  defp row_dom_id(row), do: "row-" <> to_string(row_id(row))

  defp group_id_for(category) do
    "grp-" <> slug(to_string(category))
  end

  defp group_id_for(category, cluster) do
    "grp-" <> slug(to_string(category)) <> "-" <> slug(to_string(cluster))
  end

  @impl true
  def handle_event("select_tab", %{"table" => name}, socket) do
    send(self(), {:data_table_switch_tab, name})
    {:noreply, socket}
  end

  def handle_event("toggle_row_selection", %{"row-id" => id}, socket) do
    table = socket.assigns[:active_table] || "main"
    send(self(), {:data_table_toggle_row, table, id})
    {:noreply, socket}
  end

  def handle_event("toggle_all_selection", _params, socket) do
    table = socket.assigns[:active_table] || "main"
    visible_ids = current_visible_row_ids(socket)
    send(self(), {:data_table_toggle_all, table, visible_ids})
    {:noreply, socket}
  end

  def handle_event("clear_selection", _params, socket) do
    table = socket.assigns[:active_table] || "main"
    send(self(), {:data_table_clear_selection, table})
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

  def handle_event("open_save_dialog", _params, socket) do
    name = library_name_from_table(socket.assigns[:active_table])
    {:noreply, assign(socket, action_dialog: {:save, name})}
  end

  def handle_event("open_publish_dialog", _params, socket) do
    name = library_name_from_table(socket.assigns[:active_table])
    {:noreply, assign(socket, action_dialog: {:publish, name})}
  end

  def handle_event("open_suggest_dialog", _params, socket) do
    {:noreply, assign(socket, action_dialog: {:suggest, 5})}
  end

  def handle_event("close_dialog", _params, socket) do
    {:noreply, assign(socket, :action_dialog, nil)}
  end

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, :flash_message, nil)}
  end

  def handle_event("confirm_save", %{"name" => name}, socket) do
    active_table = socket.assigns[:active_table] || "main"
    send(self(), {:data_table_save, active_table, String.trim(name)})
    {:noreply, socket |> assign(:action_dialog, nil) |> assign(:flash_message, "Saving...")}
  end

  def handle_event("confirm_publish", %{"name" => name, "version_tag" => version_tag}, socket) do
    active_table = socket.assigns[:active_table] || "main"

    tag =
      case String.trim(version_tag) do
        "" -> nil
        t -> t
      end

    send(self(), {:data_table_publish, active_table, String.trim(name), tag})
    {:noreply, socket |> assign(:action_dialog, nil) |> assign(:flash_message, "Publishing...")}
  end

  def handle_event("confirm_suggest", %{"n" => n_str}, socket) do
    active_table = socket.assigns[:active_table] || "main"
    session_id = socket.assigns[:session_id]
    n = clamp_suggest_n(n_str)

    send(self(), {:suggest_skills, n, active_table, session_id})

    {:noreply,
     socket
     |> assign(:action_dialog, nil)
     |> assign(:flash_message, "Suggesting #{n} skills...")}
  end

  def handle_event("fork_library", _params, socket) do
    active_table = socket.assigns[:active_table] || "main"
    send(self(), {:data_table_fork, active_table})
    {:noreply, assign(socket, :flash_message, "Forking...")}
  end

  def handle_event("toggle_export_menu", _params, socket) do
    {:noreply, assign(socket, :export_menu_open, !socket.assigns.export_menu_open)}
  end

  def handle_event("close_export_menu", _params, socket) do
    {:noreply, assign(socket, :export_menu_open, false)}
  end

  def handle_event("export_csv", _params, socket) do
    rows = socket.assigns.rows
    schema = socket.assigns.schema
    active_table = socket.assigns[:active_table] || "main"

    csv = build_csv(rows, schema)
    filename = String.replace(active_table, ~r/[^a-zA-Z0-9_-]/, "_") <> ".csv"

    socket =
      socket
      |> assign(:export_menu_open, false)
      |> push_event("csv-download", %{csv: csv, filename: filename})

    {:noreply, socket}
  end

  def handle_event("export_xlsx", _params, socket) do
    rows = socket.assigns.rows
    schema = socket.assigns.schema
    active_table = socket.assigns[:active_table] || "main"

    xlsx_binary = build_xlsx(rows, schema)
    b64 = Base.encode64(xlsx_binary)
    filename = String.replace(active_table, ~r/[^a-zA-Z0-9_-]/, "_") <> ".xlsx"

    socket =
      socket
      |> assign(:export_menu_open, false)
      |> push_event("xlsx-download", %{data: b64, filename: filename})

    {:noreply, socket}
  end

  def handle_event("start_edit", %{"id" => id, "field" => field}, socket) do
    col = find_column(socket.assigns.schema, field)

    if col && col.editable do
      {parent_id, child_index} = parse_compound_id(id)

      socket =
        socket
        |> assign(:editing, {id, field})
        |> optimistic_stream_update(parent_id, child_index)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_edit", %{"row_id" => id, "field" => field, "value" => value}, socket) do
    session_id = socket.assigns.session_id
    active_table = socket.assigns[:active_table] || "main"

    {parent_id, child_index} = parse_compound_id(id)

    # Child rows are addressed by their natural key (per the schema's
    # child_key_fields), not by list position. Look up the child at
    # `child_index` from the rendered row and pull its key values to
    # build a stable child_key map for the change.
    change =
      if child_index do
        build_child_change(socket.assigns, parent_id, child_index, field, value)
      else
        %{"id" => parent_id, "field" => field, "value" => value}
      end

    # Optimistic overlay so the UI updates immediately even if the
    # server round-trip and invalidation event haven't landed yet.
    optimistic =
      Map.put(socket.assigns.optimistic_edits, {parent_id, child_index, field}, value)

    socket =
      socket
      |> assign(:optimistic_edits, optimistic)
      |> assign(:editing, nil)
      |> optimistic_stream_update(parent_id, child_index)

    case DataTable.update_cells(session_id, [change], table: active_table) do
      :ok ->
        # Nudge the parent LV to refetch the snapshot immediately. The
        # server's :table_changed event will also arrive via pubsub,
        # but this avoids waiting for it.
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

    change = %{"id" => id, "field" => "resolution", "value" => resolution}

    optimistic =
      Map.put(socket.assigns.optimistic_edits, {id, nil, "resolution"}, resolution)

    socket =
      socket
      |> assign(:optimistic_edits, optimistic)
      |> optimistic_stream_update(id)

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
      if parent_id, do: optimistic_stream_update(socket, parent_id, child_index), else: socket

    {:noreply, socket}
  end

  def handle_event("toggle_group", %{"group" => group_id}, socket) do
    collapsed =
      case socket.assigns.collapsed do
        :all_collapsed ->
          # Materialize so we can remove this one group
          grouped = socket.assigns.grouped
          collect_all_group_ids(grouped) |> MapSet.delete(group_id)

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

    # Row-level expansion (panel mode) toggles drive a stream
    # insert/delete because the panel `<tr>` rides as its own stream
    # item. Group-level toggles need to populate the stream lazily on
    # first expand.
    socket =
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

    {:noreply, socket}
  end

  # Phoenix LV fires `phx-viewport-bottom` once per scroll-to-end. We
  # append the next window of rows to the existing stream (no reset) so
  # only the new entries land in the diff.
  def handle_event("load_more_in_group", %{"group" => group_id}, socket) do
    streamed = socket.assigns[:_streamed_groups] || %{}

    case Map.get(streamed, group_id) do
      nil ->
        # Stream wasn't seeded — ignore. The viewport handler can't fire
        # before the first render anyway, but this guards against races.
        {:noreply, socket}

      %{loaded: loaded, total: total} when loaded >= total ->
        {:noreply, socket}

      %{loaded: loaded, total: _total} ->
        page_size = socket.assigns[:stream_page_size] || @default_stream_page_size
        schema = socket.assigns.schema
        panel_mode = Map.get(schema, :children_display, :rows) == :panel
        collapsed = socket.assigns.collapsed

        rows = lookup_group_rows(socket.assigns.grouped, group_id)
        next_window = rows |> Enum.slice(loaded, page_size)
        items = build_stream_items(next_window, panel_mode, collapsed)

        {socket, stream_name} = stream_name_for_group(socket, group_id)
        socket = ensure_stream_configured(socket, stream_name)
        socket = stream(socket, stream_name, items)

        new_loaded = loaded + length(next_window)

        meta = %{
          total: length(rows),
          loaded: new_loaded,
          sort: {socket.assigns.sort_by, socket.assigns.sort_dir}
        }

        socket = assign(socket, :_streamed_groups, Map.put(streamed, group_id, meta))
        {:noreply, socket}
    end
  end

  # --- Group header editing (category/cluster) ---

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

      # Find all rows matching the old group value and update them
      rows = socket.assigns.rows

      changes =
        rows
        |> Enum.filter(fn row ->
          val = Map.get(row, String.to_existing_atom(field)) || Map.get(row, field)
          to_string(val) == old_value
        end)
        |> Enum.map(fn row ->
          %{"id" => to_string(row_id(row)), "field" => field, "value" => new_value}
        end)

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

  # --- Add / Delete rows ---

  def handle_event("add_row", params, socket) do
    session_id = socket.assigns.session_id
    active_table = socket.assigns[:active_table] || "main"
    schema = socket.assigns.schema

    # Build row with non-empty placeholders for required text fields.
    # The storage schema rejects "" for required columns, so we use
    # "(new)" as a visible placeholder the user can immediately edit.
    row =
      schema.columns
      |> Map.new(fn col ->
        default =
          case col.type do
            :number -> 0
            _ -> "(new)"
          end

        {col.key, default}
      end)
      |> maybe_put(params, "category")
      |> maybe_put(params, "cluster")

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
          |> optimistic_stream_delete(id)
          |> assign(:confirm_delete, nil)

        send(self(), {:data_table_refresh, active_table})
        {:noreply, socket}

      {:error, reason} ->
        send(self(), {:data_table_error, reason})
        {:noreply, assign(socket, :confirm_delete, nil)}
    end
  end

  # --- Add / Delete child rows (proficiency levels) ---

  def handle_event("add_child", %{"parent-id" => parent_id}, socket) do
    session_id = socket.assigns.session_id
    active_table = socket.assigns[:active_table] || "main"
    schema = socket.assigns.schema
    children_key = schema.children_key

    row = find_row(socket.assigns.rows, parent_id)
    children = (row && Map.get(row, children_key)) || []

    # Next level number = max existing + 1
    next_level = next_child_level(children)

    blank_child =
      schema.child_columns
      |> Map.new(fn col ->
        default = if col.type == :number, do: 0, else: ""
        {col.key, default}
      end)
      |> Map.put(:level, next_level)

    new_children = children ++ [blank_child]
    change = %{"id" => parent_id, "field" => to_string(children_key), "value" => new_children}

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
    schema = socket.assigns.schema
    children_key = schema.children_key

    row = find_row(socket.assigns.rows, parent_id)
    children = (row && Map.get(row, children_key)) || []
    {idx, ""} = Integer.parse(idx_str)

    new_children = List.delete_at(children, idx)
    change = %{"id" => parent_id, "field" => to_string(children_key), "value" => new_children}

    case DataTable.update_cells(session_id, [change], table: active_table) do
      :ok ->
        send(self(), {:data_table_refresh, active_table})
        {:noreply, socket}

      {:error, reason} ->
        send(self(), {:data_table_error, reason})
        {:noreply, socket}
    end
  end

  # --- Column sorting ---

  def handle_event("sort_column", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)

    {new_sort_by, new_sort_dir} =
      case {socket.assigns.sort_by, socket.assigns.sort_dir} do
        {^field_atom, :asc} -> {field_atom, :desc}
        {^field_atom, :desc} -> {nil, :asc}
        _ -> {field_atom, :asc}
      end

    rows = socket.assigns.rows
    sorted = sort_rows(rows, new_sort_by, new_sort_dir)
    grouped = group_rows(sorted, socket.assigns.schema.group_by)

    socket =
      socket
      |> assign(:sort_by, new_sort_by)
      |> assign(:sort_dir, new_sort_dir)
      |> assign(:grouped, grouped)

    # Reset every populated group's stream to the first window in the
    # new order. Collapsed/un-streamed groups stay zero-cost.
    socket = reset_populated_streams(socket, grouped)

    {:noreply, socket}
  end

  # Walks every group_id currently in `_streamed_groups` and re-seeds
  # its stream from the freshly-sorted/grouped row list, preserving the
  # streamed-ness but reverting `loaded` to the first page so
  # `load_more_in_group` continues from a consistent offset.
  defp reset_populated_streams(socket, grouped) do
    streamed = socket.assigns[:_streamed_groups] || %{}
    schema = socket.assigns.schema
    panel_mode = Map.get(schema, :children_display, :rows) == :panel
    page_size = socket.assigns[:stream_page_size] || @default_stream_page_size
    collapsed = socket.assigns.collapsed
    sort_key = {socket.assigns.sort_by, socket.assigns.sort_dir}

    Enum.reduce(streamed, socket, fn {group_id, _meta}, acc ->
      rows = lookup_group_rows(grouped, group_id)

      {new_acc, _meta} =
        seed_group_stream(acc, group_id, rows, panel_mode, collapsed, page_size, sort_key)

      new_acc
    end)
  end

  defp more_pages?(streamed, group_id) do
    case streamed && Map.get(streamed, group_id) do
      %{loaded: loaded, total: total} when loaded < total -> true
      _ -> false
    end
  end

  # Phase E: targeted stream_insert for the row currently being edited
  # so the optimistic overlay shows up before the server roundtrip.
  # `stream_insert/4` with the same dom_id replaces in place — the
  # whole group's stream isn't rebuilt.
  #
  # When `child_index` is non-nil, also re-inserts the proficiency panel
  # stream item so child-cell edits (level name/description) re-render
  # with the latest `editing` assign and optimistic value. The panel
  # item is only re-inserted when the caller indicates a child edit —
  # we don't want to introduce a panel item for a row whose panel
  # wasn't already rendered (i.e. parent-cell edits on collapsed rows).
  defp optimistic_stream_update(socket, parent_id, child_index \\ nil) do
    rows = socket.assigns[:rows] || []

    case find_row(rows, to_string(parent_id)) do
      nil ->
        socket

      row ->
        updated_base =
          apply_optimistic_row(row, to_string(parent_id), socket.assigns.optimistic_edits)

        updated_parent = Map.put(updated_base, :_kind, :parent)

        case stream_for_row(socket, updated_parent) do
          {:ok, stream_name} ->
            socket = stream_insert(socket, stream_name, updated_parent)

            if child_index != nil do
              stream_insert(socket, stream_name, Map.put(updated_base, :_kind, :panel))
            else
              socket
            end

          :none ->
            socket
        end
    end
  end

  # Phase E: stream_delete the parent (and its panel item, if any) on
  # row delete. The server-side invalidation will eventually re-seed
  # the group, but this drops the row from the DOM immediately.
  defp optimistic_stream_delete(socket, id) do
    rows = socket.assigns[:rows] || []

    case find_row(rows, to_string(id)) do
      nil ->
        socket

      row ->
        case stream_for_row(socket, row) do
          {:ok, stream_name} ->
            socket
            |> stream_delete(stream_name, Map.put(row, :_kind, :parent))
            |> stream_delete(stream_name, Map.put(row, :_kind, :panel))

          :none ->
            socket
        end
    end
  end

  defp stream_for_row(socket, row) do
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

  # First-expand population: if this group hasn't been streamed yet,
  # seed its first window from the current row list.
  defp populate_group_on_expand(socket, group_id, collapsed) do
    streamed = socket.assigns[:_streamed_groups] || %{}

    if group_streamed?(streamed, group_id) do
      socket
    else
      schema = socket.assigns.schema
      panel_mode = Map.get(schema, :children_display, :rows) == :panel
      page_size = socket.assigns[:stream_page_size] || @default_stream_page_size
      sort_key = {socket.assigns.sort_by, socket.assigns.sort_dir}
      rows = lookup_group_rows(socket.assigns.grouped, group_id)

      {socket, _meta} =
        seed_group_stream(socket, group_id, rows, panel_mode, collapsed, page_size, sort_key)

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
        # Parent group was never streamed → nothing to update; the
        # parent row isn't in DOM yet anyway.
        socket

      true ->
        # Re-seed the affected leaf group's stream so the panel item
        # lands right after its parent. `stream_insert/4` only supports
        # numeric/at positions, not "after dom_id X", so a full re-seed
        # of this single group is the simplest way to keep parent +
        # panel adjacent.
        page_size = socket.assigns[:stream_page_size] || @default_stream_page_size
        sort_key = {socket.assigns.sort_by, socket.assigns.sort_dir}
        rows = lookup_group_rows(socket.assigns.grouped, parent_group_id)

        {socket, _meta} =
          seed_group_stream(
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

  defp lookup_group_rows(grouped, target_group_id) do
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["dt-panel", @class]}>
      <% active_artifact = active_artifact(@workbench_context) %>
      <%= if @error do %>
        <div class="dt-error-banner">
          <strong>Data table unavailable:</strong> <%= inspect(@error) %>
          <div class="dt-error-hint">The per-session table server is not running. Reload the page or regenerate the data.</div>
        </div>
      <% end %>

      <%= if length(@table_order || []) > 1 do %>
        <div class="dt-tab-strip">
          <%= for name <- @table_order do %>
            <% count = table_row_count(@tables, name) %>
            <% artifact = artifact_for_table(@workbench_context, name) %>
            <button
              type="button"
              phx-click="select_tab"
              phx-target={@myself}
              phx-value-table={name}
              class={"dt-tab" <> if(name == @active_table, do: " dt-tab-active", else: "")}
              title={name}
            >
              <%= artifact_tab_label(artifact, name) %>
              <span class="dt-tab-count"><%= artifact_tab_meta(artifact, count) %></span>
            </button>
          <% end %>
        </div>
      <% end %>

      <%= if MapSet.size(@selected_ids) > 0 do %>
        <div class="dt-selection-bar">
          <span class="dt-selection-count">
            <%= MapSet.size(@selected_ids) %> <%= selection_noun(active_artifact, MapSet.size(@selected_ids)) %> selected
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

      <div class="dt-artifact-header">
        <div class="dt-artifact-main">
          <div class="dt-artifact-kicker"><%= artifact_kind_label(active_artifact, @schema.title) %></div>
          <h2 class="dt-title"><%= artifact_title(active_artifact, @schema.title) %></h2>
          <div class="dt-artifact-subtitle">
            <span><%= artifact_subtitle(active_artifact, @mode_label) %></span>
            <span :if={active_artifact && active_artifact.source_label} class="dt-artifact-source">
              <%= active_artifact.source_label %>
            </span>
          </div>
          <div class="dt-metric-strip">
            <span :for={metric <- artifact_metric_labels(active_artifact, length(@rows))} class="dt-metric-pill">
              <%= metric %>
            </span>
            <span :if={@streaming} class="dt-streaming">
              streaming...
            </span>
            <span :if={@total_cost > 0} class="dt-cost">
              $<%= :erlang.float_to_binary(@total_cost / 1, decimals: 4) %>
            </span>
          </div>
        </div>
        <span
          :if={@flash_message}
          id={"dt-flash-" <> Integer.to_string(:erlang.phash2(@flash_message))}
          class="dt-flash"
        >
          <span class="dt-flash-text"><%= @flash_message %></span>
          <button
            type="button"
            class="dt-flash-close"
            phx-click="dismiss_flash"
            phx-target={@myself}
            title="Dismiss"
          >&times;</button>
        </span>
        <div class="dt-toolbar-actions">
          <button
            :if={candidates_view?(@view_key, @active_table)}
            type="button"
            class="dt-action-btn dt-candidates-done-btn"
            phx-click="candidates_done"
            phx-target={@myself}
            title="Use the checked rows to seed a new framework"
          >
            ✓ Done — Seed Framework
          </button>
          <button
            :if={library_view?(@view_key, @active_table)}
            type="button"
            class="dt-action-btn dt-save-btn"
            phx-click="open_save_dialog"
            phx-target={@myself}
            title="Save to library"
          >
            Save
          </button>
          <button
            :if={library_view?(@view_key, @active_table)}
            type="button"
            class="dt-action-btn dt-publish-btn"
            phx-click="open_publish_dialog"
            phx-target={@myself}
            title="Publish as immutable version"
          >
            Publish
          </button>
          <button
            :if={library_view?(@view_key, @active_table)}
            type="button"
            class="dt-action-btn dt-fork-btn"
            phx-click="fork_library"
            phx-target={@myself}
            title="Fork as new library"
          >
            Fork
          </button>
          <button
            :if={library_view?(@view_key, @active_table)}
            type="button"
            class="dt-action-btn dt-suggest-btn"
            phx-click="open_suggest_dialog"
            phx-target={@myself}
            title="Ask the model for additional skills"
          >
            Suggest
          </button>
          <div
            class="dt-export-dropdown"
            id={"dt-export-" <> (@active_table || "main")}
            phx-hook="ExportDownload"
          >
            <button
              type="button"
              class="dt-action-btn dt-export-btn"
              phx-click="toggle_export_menu"
              phx-target={@myself}
            >
              Export &#9662;
            </button>
            <div class={"dt-export-menu" <> if(@export_menu_open, do: " dt-export-menu-open", else: "")}>
              <button type="button" class="dt-export-option" phx-click="export_csv" phx-target={@myself}>
                CSV (.csv)
              </button>
              <button type="button" class="dt-export-option" phx-click="export_xlsx" phx-target={@myself}>
                Excel (.xlsx)
              </button>
            </div>
          </div>
          <button type="button" class="dt-add-row-btn" phx-click="add_row" phx-target={@myself} title="Add row">
            + Add Row
          </button>
        </div>
      </div>

      <.workbench_surface_notice
        artifact={active_artifact}
        surface={artifact_surface(active_artifact)}
        selected_count={MapSet.size(@selected_ids)}
      />

      <%= if @action_dialog do %>
        <div class="dt-dialog-backdrop" phx-click="close_dialog" phx-target={@myself}>
          <div class="dt-dialog" phx-click-away="close_dialog" phx-target={@myself}>
            <%= case @action_dialog do %>
              <% {:save, name} -> %>
                <h3 class="dt-dialog-title">Save Library</h3>
                <form phx-submit="confirm_save" phx-target={@myself}>
                  <label class="dt-dialog-label">Library Name</label>
                  <input type="text" name="name" value={name} class="dt-dialog-input" phx-hook="AutoFocus" id="save-dialog-name" />
                  <div class="dt-dialog-actions">
                    <button type="button" class="dt-dialog-btn dt-dialog-cancel" phx-click="close_dialog" phx-target={@myself}>Cancel</button>
                    <button type="submit" class="dt-dialog-btn dt-dialog-confirm dt-save-btn">Save</button>
                  </div>
                </form>
              <% {:publish, name} -> %>
                <h3 class="dt-dialog-title">Publish Library</h3>
                <form phx-submit="confirm_publish" phx-target={@myself}>
                  <label class="dt-dialog-label">Library Name</label>
                  <input type="text" name="name" value={name} class="dt-dialog-input" phx-hook="AutoFocus" id="publish-dialog-name" />
                  <label class="dt-dialog-label">Version Tag <span class="dt-dialog-hint">(e.g. 2026.1 — auto-generated if blank)</span></label>
                  <input type="text" name="version_tag" value="" class="dt-dialog-input" id="publish-dialog-version" placeholder="auto" />
                  <div class="dt-dialog-actions">
                    <button type="button" class="dt-dialog-btn dt-dialog-cancel" phx-click="close_dialog" phx-target={@myself}>Cancel</button>
                    <button type="submit" class="dt-dialog-btn dt-dialog-confirm dt-publish-btn">Publish</button>
                  </div>
                </form>
              <% {:suggest, default_n} -> %>
                <h3 class="dt-dialog-title">Suggest more skills</h3>
                <form phx-submit="confirm_suggest" phx-target={@myself}>
                  <label class="dt-dialog-label">How many? <span class="dt-dialog-hint">(1–10)</span></label>
                  <input type="number" name="n" value={default_n} min="1" max="10" class="dt-dialog-input" phx-hook="AutoFocus" id="suggest-dialog-n" />
                  <div class="dt-dialog-actions">
                    <button type="button" class="dt-dialog-btn dt-dialog-cancel" phx-click="close_dialog" phx-target={@myself}>Cancel</button>
                    <button type="submit" class="dt-dialog-btn dt-dialog-confirm dt-suggest-btn">Suggest</button>
                  </div>
                </form>
            <% end %>
          </div>
        </div>
      <% end %>

      <div class="dt-table-wrap">
        <%= if @grouped == [] do %>
          <div class="dt-empty"><%= @schema.empty_message %></div>
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
                <span class="dt-group-count" phx-click="toggle_group" phx-target={@myself} phx-value-group={group_id}><%= count_nested_rows(children) %> rows</span>
                <button type="button" class="dt-group-add-btn" phx-click="add_row" phx-target={@myself}
                  phx-value-category={group_label}
                  title={"Add skill to #{group_label}"}>+</button>
              </div>
              <div class={"dt-group-content" <> if(collapsed?(@collapsed, group_id), do: " dt-hidden", else: "")}>
                <%= case children do %>
                  <% {:rows, _rows} -> %>
                    <% stream_atom = Map.get(@_group_to_stream, group_id) %>
                    <.data_table_rows
                      stream={stream_atom && Map.get(@streams, stream_atom)}
                      group_id={group_id}
                      more_pages?={more_pages?(@_streamed_groups, group_id)}
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
                    <.add_row_in_group myself={@myself} group_by={group_by} group_label={group_label} sub_label={nil} />
                  <% {:nested, sub_groups} -> %>
                    <% l2_field = Enum.at(group_by, 1) %>
                    <%= for {sub_label, rows} <- sub_groups do %>
                      <% sub_id = "grp-" <> slug(group_label) <> "-" <> slug(sub_label) %>
                      <% sub_stream_atom = Map.get(@_group_to_stream, sub_id) %>
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
                            more_pages?={more_pages?(@_streamed_groups, sub_id)}
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
                          <.add_row_in_group myself={@myself} group_by={group_by} group_label={group_label} sub_label={sub_label} />
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

  attr(:artifact, :any, default: nil)
  attr(:surface, :atom, default: :artifact_summary)
  attr(:selected_count, :integer, default: 0)

  defp workbench_surface_notice(assigns) do
    assigns = assign(assigns, :metrics, surface_metrics(assigns.artifact))

    ~H"""
    <div :if={surface_notice?(@surface)} class={"dt-surface-notice dt-surface-#{@surface}"}>
      <%= case @surface do %>
        <% :linked_artifacts -> %>
          <div class="dt-surface-copy">
            <span class="dt-surface-label">Linked artifacts</span>
            <strong>Review the related workbench artifacts together</strong>
            <span><%= linked_artifact_summary(@artifact) %></span>
          </div>
        <% :role_candidate_picker -> %>
          <div class="dt-surface-copy">
            <span class="dt-surface-label">Picker</span>
            <strong>Choose source roles for the next framework</strong>
            <span><%= @metrics[:candidates] || 0 %> candidates across <%= @metrics[:queries] || 0 %> queries</span>
          </div>
          <div class="dt-surface-count">
            <strong><%= @selected_count %></strong>
            <span>selected</span>
          </div>
        <% :conflict_review -> %>
          <div class="dt-surface-copy">
            <span class="dt-surface-label">Decision queue</span>
            <strong>Resolve combine conflicts before creating the merged library</strong>
            <span><%= @metrics[:unresolved] || 0 %> unresolved, <%= @metrics[:resolved] || 0 %> resolved</span>
          </div>
          <div class={"dt-surface-state #{if (@metrics[:unresolved] || 0) == 0, do: "is-ready", else: "needs-work"}"}>
            <%= if (@metrics[:unresolved] || 0) == 0, do: "Ready to merge", else: "Needs decisions" %>
          </div>
        <% :dedup_review -> %>
          <div class="dt-surface-copy">
            <span class="dt-surface-label">Review queue</span>
            <strong>Decide which duplicate candidates should be merged or kept</strong>
            <span><%= @metrics[:unresolved] || 0 %> unresolved, <%= @metrics[:resolved] || 0 %> resolved</span>
          </div>
          <div class={"dt-surface-state #{if (@metrics[:unresolved] || 0) == 0, do: "is-ready", else: "needs-work"}"}>
            <%= if (@metrics[:unresolved] || 0) == 0, do: "Ready to apply", else: "Needs review" %>
          </div>
        <% :gap_review -> %>
          <div class="dt-surface-copy">
            <span class="dt-surface-label">Recommendations</span>
            <strong>Review proposed changes before applying them to the artifact</strong>
            <span>
              <%= @metrics[:recommendations] || @metrics[:rows] || 0 %> findings,
              <%= @metrics[:high_priority] || 0 %> high priority,
              <%= @metrics[:unresolved] || 0 %> unresolved
            </span>
          </div>
          <div class={"dt-surface-state #{if (@metrics[:unresolved] || 0) == 0, do: "is-ready", else: "needs-work"}"}>
            <%= if (@metrics[:unresolved] || 0) == 0, do: "Ready to apply", else: "Needs review" %>
          </div>
        <% _ -> %>
      <% end %>
    </div>
    """
  end

  # --- Table rows sub-component ---
  #
  # Renders one leaf-group's table. The row body is backed by a Phoenix
  # LiveView stream so the LV diff size stays bounded as the row count
  # grows. Each stream item is tagged with `:_kind` (`:parent` or
  # `:panel`); panel-mode expansion rows ride along as their own stream
  # entries with dom_id `panel-<row_id>` (see `build_stream_items/3`).

  defp data_table_rows(assigns) do
    visible_columns =
      Enum.reject(assigns.schema.columns, fn col -> col.key in assigns.schema.group_by end)

    has_children = assigns.schema.children_key != nil
    child_columns = assigns.schema.child_columns || []
    children_key = assigns.schema.children_key
    show_id = Map.get(assigns.schema, :show_id, true)
    panel_mode = Map.get(assigns.schema, :children_display, :rows) == :panel

    assigns =
      assign(assigns,
        visible_columns: visible_columns,
        has_children: has_children,
        child_columns: child_columns,
        children_key: children_key,
        show_id: show_id,
        panel_mode: panel_mode,
        panel_colspan: length(visible_columns) + 5
      )

    ~H"""
    <table class="dt-table">
      <thead>
        <tr>
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
              <.proficiency_panel_row
                dom_id={dom_id}
                row={row}
                children_key={@children_key}
                editing={@editing}
                myself={@myself}
                panel_colspan={@panel_colspan}
              />
            <% _ -> %>
              <.parent_row
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
      </tbody>
    </table>
    """
  end

  # Renders one parent row, branching on whether the schema has
  # children (and panel mode) so the markup matches the pre-stream
  # output cell-for-cell.
  defp parent_row(assigns) do
    row_id_str = to_string(row_id(assigns.row))

    expanded? =
      assigns.has_children and not collapsed?(assigns.collapsed, "row-" <> row_id_str)

    children =
      if assigns.has_children do
        Map.get(assigns.row, assigns.children_key) ||
          Map.get(assigns.row, to_string(assigns.children_key)) || []
      else
        []
      end

    selected? = MapSet.member?(assigns.selected_ids, row_id_str)

    assigns =
      assign(assigns,
        row_id_str: row_id_str,
        expanded?: expanded?,
        children: children,
        selected?: selected?
      )

    ~H"""
    <%= if @has_children do %>
      <tr id={@dom_id} class={[
        "dt-row dt-parent-row",
        @expanded? && @panel_mode && "dt-skill-expanded",
        @selected? && "dt-row-selected"
      ]}>
        <.row_select_cell row_id={@row_id_str} selected?={@selected?} myself={@myself} />
        <td class="dt-td dt-td-expand" phx-click="toggle_group" phx-target={@myself} phx-value-group={"row-" <> @row_id_str}>
          <span class={"dt-chevron" <> if(@expanded?, do: " dt-expanded", else: "")}></span>
        </td>
        <td :if={@show_id} class="dt-td dt-td-id"><%= @row_id_str %></td>
        <td class="dt-td dt-td-source">
          <.provenance_badge source={get_cell(@row, :_source)} />
        </td>
        <.editable_cell :for={col <- @visible_columns} row={@row} col={col} editing={@editing} myself={@myself} row_id={@row_id_str} metadata={@metadata} />
        <%= if !@panel_mode do %>
          <td :for={_col <- @child_columns} class="dt-td dt-td-empty"></td>
        <% else %>
          <td class="dt-td dt-col-levels"><%= length(@children) %></td>
        <% end %>
        <td class="dt-td dt-td-row-actions">
          <.delete_button row_id={@row_id_str} confirm_delete={@confirm_delete} myself={@myself} />
        </td>
      </tr>
    <% else %>
      <tr id={@dom_id} class={["dt-row", @selected? && "dt-row-selected"]}>
        <.row_select_cell row_id={@row_id_str} selected?={@selected?} myself={@myself} />
        <td :if={@show_id} class="dt-td dt-td-id"><%= @row_id_str %></td>
        <td class="dt-td dt-td-source">
          <.provenance_badge source={get_cell(@row, :_source)} />
        </td>
        <.editable_cell :for={col <- @visible_columns} row={@row} col={col} editing={@editing} myself={@myself} row_id={@row_id_str} metadata={@metadata} />
        <td class="dt-td dt-td-row-actions">
          <.delete_button row_id={@row_id_str} confirm_delete={@confirm_delete} myself={@myself} />
        </td>
      </tr>
    <% end %>
    """
  end

  # Per-row selection checkbox cell. Sticky left column. The `phx-click`
  # only fires from the cell — clicking elsewhere on the row does not
  # toggle (avoids accidental selections during scrolling/editing).
  defp row_select_cell(assigns) do
    ~H"""
    <td class="dt-td dt-td-select" phx-click="toggle_row_selection" phx-target={@myself} phx-value-row-id={@row_id}>
      <input
        type="checkbox"
        class="dt-row-checkbox"
        checked={@selected?}
        aria-label={"Select row " <> @row_id}
        tabindex="-1"
      />
    </td>
    """
  end

  # Renders the proficiency-levels panel as a single full-width row
  # immediately following its parent. Only emitted as a stream item
  # when the parent is expanded — see `build_stream_items/3`.
  defp proficiency_panel_row(assigns) do
    row_id_str = to_string(row_id(assigns.row))

    children =
      Map.get(assigns.row, assigns.children_key) ||
        Map.get(assigns.row, to_string(assigns.children_key)) || []

    assigns = assign(assigns, row_id_str: row_id_str, children: children)

    ~H"""
    <tr id={@dom_id} class="dt-row dt-proficiency-row">
      <td colspan={@panel_colspan} style="padding: 0;">
        <div :if={@children != []} class="dt-proficiency-panel">
          <%= for {child, idx} <- @children |> Enum.with_index() |> Enum.sort_by(fn {c, _} -> get_child_level(c) end) do %>
            <% child_id = @row_id_str <> ":child:" <> to_string(idx) %>
            <div class="dt-proficiency-item">
              <span class="dt-proficiency-level">L<%= get_child_level(child) %></span>
              <.inline_editable_span id={child_id} field="level_name" value={get_cell(child, :level_name)} editing={@editing} myself={@myself} class="dt-proficiency-name" />
              <.inline_editable_span id={child_id} field="level_description" value={get_cell(child, :level_description)} editing={@editing} myself={@myself} class="dt-proficiency-desc" multiline?={true} />
              <button type="button" class="dt-child-delete-btn" phx-click="delete_child" phx-target={@myself} phx-value-parent-id={@row_id_str} phx-value-index={idx} title="Remove level">
                &times;
              </button>
            </div>
          <% end %>
        </div>
        <div class="dt-proficiency-add">
          <button type="button" class="dt-add-child-btn" phx-click="add_child" phx-target={@myself} phx-value-parent-id={@row_id_str}>
            + Add Level
          </button>
        </div>
      </td>
    </tr>
    """
  end

  # --- provenance_badge component ---
  #
  # Renders a small letter badge per row indicating who wrote it
  # (`U`ser / `F`low / `A`gent). Empty when source is missing — keeps
  # the layout aligned without needing a placeholder character.

  attr(:source, :any, default: nil)

  defp provenance_badge(assigns) do
    {label, title, klass} = badge_for(assigns.source)
    assigns = assign(assigns, label: label, title: title, klass: klass)

    ~H"""
    <span :if={@label} class={"dt-source-badge " <> @klass} title={@title}><%= @label %></span>
    """
  end

  defp badge_for(s) when s in [:user, "user"], do: {"U", "Edited by user", "dt-source-user"}
  defp badge_for(s) when s in [:flow, "flow"], do: {"F", "Written by flow", "dt-source-flow"}
  defp badge_for(s) when s in [:agent, "agent"], do: {"A", "Written by agent", "dt-source-agent"}
  defp badge_for(_), do: {nil, nil, nil}

  # --- editable_cell component ---

  defp editable_cell(assigns) do
    row_id = assigns.row_id
    editing? = assigns.editing == {row_id, Atom.to_string(assigns.col.key)}
    value = get_cell(assigns.row, assigns.col.key)

    assigns = assign(assigns, editing?: editing?, value: value, cell_row_id: row_id)

    ~H"""
    <%= if @col.type == :action do %>
      <.action_cell row={@row} col={@col} value={@value} row_id={@cell_row_id} myself={@myself} />
    <% else %>
    <td
      class={"dt-td " <> (@col.css_class || "dt-td-#{@col.key}")}
      phx-click={if @col.editable, do: "start_edit"}
      phx-target={@myself}
      phx-value-id={@cell_row_id}
      phx-value-field={@col.key}
    >
      <%= if @editing? do %>
        <form phx-submit="save_edit" phx-target={@myself}>
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
              phx-blur="save_edit"
              phx-target={@myself}
              phx-value-row_id={@cell_row_id}
              phx-value-field={@col.key}
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
              phx-value-row_id={@cell_row_id}
              phx-value-field={@col.key}
              phx-keydown="cancel_edit"
              phx-target={@myself}
              phx-key="Escape"
            />
          <% end %>
        </form>
      <% else %>
        <%= if @col.key == :skill_name && !@col.editable && @metadata[:library_id] do %>
          <span
            class="dt-cell-text dt-cell-link"
            phx-click="navigate_to_library"
            phx-target={@myself}
            phx-value-library-id={@metadata[:library_id]}
          ><%= @value %></span>
        <% else %>
          <span class="dt-cell-text"><%= @value %></span>
        <% end %>
      <% end %>
    </td>
    <% end %>
    """
  end

  defp action_cell(assigns) do
    resolved = assigns.value not in [nil, "", "unresolved"]
    assigns = assign(assigns, resolved: resolved)

    ~H"""
    <td class={"dt-td " <> (@col.css_class || "dt-td-action")}>
      <%= if @resolved do %>
        <span class="dt-resolution-badge">
          <span class="dt-resolution-icon">&#10003;</span>
          <span class="dt-resolution-label"><%= resolution_label(@value) %></span>
        </span>
      <% else %>
        <div class="dt-action-buttons">
          <button
            type="button"
            class="dt-action-btn dt-action-merge-a"
            phx-click="resolve_conflict"
            phx-target={@myself}
            phx-value-id={@row_id}
            phx-value-resolution="merge_a"
            title="Keep Skill A, absorb B's levels"
          >&#8592; A</button>
          <button
            type="button"
            class="dt-action-btn dt-action-merge-b"
            phx-click="resolve_conflict"
            phx-target={@myself}
            phx-value-id={@row_id}
            phx-value-resolution="merge_b"
            title="Keep Skill B, absorb A's levels"
          >B &#8594;</button>
          <button
            type="button"
            class="dt-action-btn dt-action-keep-both"
            phx-click="resolve_conflict"
            phx-target={@myself}
            phx-value-id={@row_id}
            phx-value-resolution="keep_both"
            title="Keep both as separate skills"
          >Both</button>
        </div>
      <% end %>
    </td>
    """
  end

  defp resolution_label("merge_a"), do: "Keep A"
  defp resolution_label("merge_b"), do: "Keep B"
  defp resolution_label("keep_both"), do: "Keep Both"
  defp resolution_label(other), do: other

  # --- Editable group name (category/cluster headers) ---

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

  # --- Inline editable span (for proficiency panel items) ---

  defp inline_editable_span(assigns) do
    editing? = assigns.editing == {assigns.id, assigns.field}

    assigns =
      assigns
      |> assign(:editing?, editing?)
      |> assign_new(:multiline?, fn -> false end)

    ~H"""
    <%= if @editing? do %>
      <form phx-submit="save_edit" phx-target={@myself} class={@class}>
        <input type="hidden" name="row_id" value={@id} />
        <input type="hidden" name="field" value={@field} />
        <%= if @multiline? do %>
          <textarea
            name="value"
            class="dt-cell-input dt-inline-input dt-inline-textarea"
            phx-hook="Autosize"
            id={"edit-#{@id}-#{@field}"}
            phx-blur="save_edit"
            phx-target={@myself}
            phx-value-row_id={@id}
            phx-value-field={@field}
            phx-keydown="cancel_edit"
            phx-target={@myself}
            phx-key="Escape"
            rows="3"
          ><%= @value %></textarea>
        <% else %>
          <input
            type="text"
            name="value"
            value={@value}
            class="dt-cell-input dt-inline-input"
            phx-hook="AutoFocus"
            id={"edit-#{@id}-#{@field}"}
            phx-blur="save_edit"
            phx-target={@myself}
            phx-value-row_id={@id}
            phx-value-field={@field}
            phx-keydown="cancel_edit"
            phx-target={@myself}
            phx-key="Escape"
          />
        <% end %>
      </form>
    <% else %>
      <span
        class={@class <> " dt-editable-hint"}
        phx-click="start_edit"
        phx-target={@myself}
        phx-value-id={@id}
        phx-value-field={@field}
      >
        <%= @value %>
      </span>
    <% end %>
    """
  end

  # --- Delete confirmation button ---

  defp delete_button(assigns) do
    ~H"""
    <%= if @confirm_delete == @row_id do %>
      <span class="dt-delete-confirm">
        <span class="dt-delete-confirm-text">Delete?</span>
        <button type="button" class="dt-delete-yes" phx-click="delete_row" phx-target={@myself} phx-value-id={@row_id}>Yes</button>
        <button type="button" class="dt-delete-no" phx-click="cancel_delete" phx-target={@myself}>No</button>
      </span>
    <% else %>
      <button type="button" class="dt-row-delete-btn" phx-click="confirm_delete" phx-target={@myself} phx-value-id={@row_id} title="Delete row">
        &times;
      </button>
    <% end %>
    """
  end

  # --- "Add row" link inside a group ---

  defp add_row_in_group(assigns) do
    group_by = assigns.group_by

    add_params =
      case {group_by, assigns.group_label, assigns.sub_label} do
        {[field1, field2 | _], label1, label2} when not is_nil(label2) ->
          %{to_string(field1) => label1, to_string(field2) => label2}

        {[field1 | _], label1, _} ->
          %{to_string(field1) => label1}

        _ ->
          %{}
      end

    assigns = assign(assigns, :add_params, add_params)

    ~H"""
    <div class="dt-group-add-row">
      <button type="button" class="dt-add-row-inline" phx-click="add_row" phx-target={@myself}
        {Enum.map(@add_params, fn {k, v} -> {"phx-value-#{k}", v} end)}>
        + Add Row
      </button>
    </div>
    """
  end

  # --- Sorting ---

  defp sort_rows(rows, nil, _dir), do: rows

  defp sort_rows(rows, field, dir) do
    Enum.sort_by(
      rows,
      fn row ->
        val = Map.get(row, field) || Map.get(row, to_string(field)) || ""
        if is_binary(val), do: String.downcase(val), else: val
      end,
      if(dir == :desc, do: :desc, else: :asc)
    )
  end

  # --- Row lookup helpers ---

  defp find_row(row_entries, id) do
    Enum.find(row_entries, fn row -> to_string(row_id(row)) == id end)
  end

  defp next_child_level(children) do
    children
    |> Enum.reduce(fn el, best -> max(get_child_level(el), best) end)
    |> Kernel.+(1)
  end

  defp maybe_put(map, params, key) do
    case Map.get(params, key) do
      nil ->
        map

      "" ->
        map

      val ->
        atom_key =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> key
          end

        Map.put(map, atom_key, val)
    end
  end

  # --- Collapsed state helpers ---

  defp collapsed?(:all_collapsed, _id), do: true
  defp collapsed?(set, id), do: MapSet.member?(set, id)

  # --- Collect all group IDs for default-collapsed state ---

  defp collect_all_group_ids(group_tree) do
    Enum.reduce(group_tree, MapSet.new(), fn {group_label, children}, acc ->
      group_id = group_id_for(group_label)
      new_acc = MapSet.put(acc, group_id)

      case children do
        {:nested, child_groups} ->
          Enum.reduce(child_groups, new_acc, fn {sub_label, _rows}, inner_acc ->
            MapSet.put(inner_acc, group_id_for(group_label, sub_label))
          end)

        {:rows, _} ->
          new_acc
      end
    end)
  end

  # --- Grouping helpers (operate on ordered list, not rows_map) ---

  defp group_rows([], _group_by), do: []

  defp group_rows(rows, []), do: [{"All", {:rows, rows}}]

  defp group_rows(row_entries, [field]) do
    row_entries
    |> group_preserving_order(field)
    |> Enum.map(fn {label, group_rows} -> {label, {:rows, group_rows}} end)
  end

  defp group_rows(row_entries, [field1, field2 | _]) do
    row_entries
    |> group_preserving_order(field1)
    |> Enum.map(fn {label, group_rows} ->
      sub_groups = group_preserving_order(group_rows, field2)
      {label, {:nested, sub_groups}}
    end)
  end

  defp group_preserving_order(group_entries, field) do
    str_field = if is_atom(field), do: Atom.to_string(field), else: field

    {groups, order} =
      Enum.reduce(group_entries, {%{}, %{}}, fn row, {groups, order} ->
        key =
          (Map.get(row, field) || Map.get(row, str_field) || "")
          |> to_string()

        new_groups = Map.update(groups, key, [row], &[row | &1])
        new_order = Map.put_new(order, key, map_size(order))
        {new_groups, new_order}
      end)

    order
    |> Enum.sort_by(fn {_key, idx} -> idx end)
    |> Enum.map(fn {key, _} -> {key, Enum.reverse(Map.get(groups, key, []))} end)
  end

  defp count_nested_rows({:rows, rows}), do: length(rows)

  defp count_nested_rows({:nested, nested_groups}) do
    Enum.reduce(nested_groups, 0, fn {_label, rows}, acc -> acc + length(rows) end)
  end

  # --- Lookup helpers ---

  defp row_id(row) do
    Rho.MapAccess.get(row, :id)
  end

  # Visible rows = the active table's rows (post-filter, post-sort) that the
  # user can reach in the panel. The select-all checkbox toggles exactly
  # this set against the current selection.
  defp current_visible_row_ids(socket) do
    visible_row_ids(socket.assigns[:rows])
  end

  defp visible_row_ids(visible_rows) when is_list(visible_rows) do
    Enum.reduce(visible_rows, [], fn row, acc ->
      case row_id(row) do
        nil -> acc
        id -> [to_string(id) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp visible_row_ids(_), do: []

  defp compute_select_all_state(rows, %MapSet{} = selected) do
    visible = MapSet.new(visible_row_ids(rows))

    cond do
      MapSet.size(visible) == 0 -> :none
      MapSet.subset?(visible, selected) -> :all
      MapSet.disjoint?(visible, selected) -> :none
      true -> :some
    end
  end

  defp compute_select_all_state(_rows, _), do: :none

  defp get_cell(row, key) when is_atom(key) do
    Map.get(row, key) || Map.get(row, Atom.to_string(key)) || ""
  end

  defp get_child_level(child) do
    (Rho.MapAccess.get(child, :level) || 0)
    |> to_integer()
  end

  defp to_integer(v) when is_integer(v), do: v
  defp to_integer(v) when is_binary(v), do: String.to_integer(v)
  defp to_integer(_), do: 0

  defp find_column(schema, field_name) when is_binary(field_name) do
    Enum.find(schema.columns, &(Atom.to_string(&1.key) == field_name)) ||
      Enum.find(schema.child_columns || [], &(Atom.to_string(&1.key) == field_name))
  end

  defp find_column(_, _), do: nil

  defp slug(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp slug(_), do: "unknown"

  defp csv_escape(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp library_name_from_table("library:" <> name), do: name
  defp library_name_from_table(_), do: ""

  defp library_view?(view_key, active_table) do
    view_key in [:skill_library, "skill_library"] or
      (is_binary(active_table) and String.starts_with?(active_table, "library:"))
  end

  defp candidates_view?(view_key, active_table) do
    view_key in [:role_candidates, "role_candidates"] or active_table == "role_candidates"
  end

  defp clamp_suggest_n(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> clamp_suggest_n(n)
      :error -> 5
    end
  end

  defp clamp_suggest_n(n) when is_integer(n), do: n |> max(1) |> min(10)
  defp clamp_suggest_n(_), do: 5

  defp build_csv(export_rows, schema) do
    csv_columns = Enum.reject(schema.columns, fn col -> col.type == :action end)
    csv_child_columns = schema.child_columns || []
    children_key = schema.children_key

    has_children = children_key != nil and csv_child_columns != []

    all_headers = csv_headers(csv_columns, csv_child_columns, has_children)

    header = Enum.map_join(all_headers, ",", &csv_escape/1)

    data_lines =
      Enum.flat_map(export_rows, fn row ->
        parent_cells = csv_parent_cells(row, csv_columns)

        if has_children do
          csv_child_lines(row, children_key, csv_child_columns, parent_cells)
        else
          [Enum.join(parent_cells, ",")]
        end
      end)

    header <> "\n" <> Enum.join(data_lines, "\n")
  end

  defp csv_parent_cells(row, parent_columns) do
    Enum.map(parent_columns, fn col ->
      val = Map.get(row, col.key) || Map.get(row, Atom.to_string(col.key)) || ""
      csv_escape(to_string(val))
    end)
  end

  defp csv_headers(header_parent_columns, header_child_columns, has_children) do
    parent_labels = Enum.map(header_parent_columns, & &1.label)

    if has_children do
      parent_labels ++ Enum.map(header_child_columns, & &1.label)
    else
      parent_labels
    end
  end

  defp csv_child_lines(row, children_key, csv_child_columns, parent_cells) do
    children = Map.get(row, children_key) || Map.get(row, Atom.to_string(children_key)) || []

    case children do
      [] ->
        blank_children = List.duplicate("", length(csv_child_columns))
        [Enum.join(parent_cells ++ blank_children, ",")]

      children_entries when is_list(children_entries) ->
        Enum.map(children_entries, fn child ->
          child_cells = csv_child_cells(child, csv_child_columns)
          Enum.join(parent_cells ++ child_cells, ",")
        end)
    end
  end

  defp csv_child_cells(child, csv_children_columns) do
    Enum.map(csv_children_columns, fn col ->
      val = Map.get(child, col.key) || Map.get(child, Atom.to_string(col.key)) || ""
      csv_escape(to_string(val))
    end)
  end

  defp build_xlsx(export_rows, schema) do
    xlsx_columns = Enum.reject(schema.columns, fn col -> col.type == :action end)
    xlsx_child_columns = schema.child_columns || []
    children_key = schema.children_key

    has_children = children_key != nil and xlsx_child_columns != []

    all_cols =
      if has_children, do: xlsx_columns ++ xlsx_child_columns, else: xlsx_columns

    # Styled header row: bold white text on dark background
    header_style = [bold: true, bg_color: "#2B579A", color: "#FFFFFF", size: 11]

    header_row = Enum.map(all_cols, fn col -> [col.label | header_style] end)

    # Build data rows grouped by parent row (skill), with alternating
    # background color per skill group and a separator border on the
    # last row of each group (gridlines are hidden).
    stripe_color = "#F2F6FC"
    separator = [bottom: [style: :thin, color: "#C0C0C0"]]

    {data_rows, _group_idx} =
      Enum.flat_map_reduce(export_rows, 0, fn row, group_idx ->
        raw_rows =
          xlsx_raw_rows(row, xlsx_columns, children_key, xlsx_child_columns, has_children)

        striped? = rem(group_idx, 2) == 1
        styled_rows = style_xlsx_rows(raw_rows, striped?, stripe_color, separator)

        {styled_rows, group_idx + 1}
      end)

    # Calculate column widths from content (capped at 60)
    all_rows = [xlsx_header_labels(all_cols) | data_rows]
    col_widths = xlsx_column_widths(all_rows)

    sheet =
      %Elixlsx.Sheet{
        name: schema.title || "Data",
        rows: [header_row | data_rows],
        col_widths: col_widths,
        show_grid_lines: false
      }
      |> Elixlsx.Sheet.set_row_height(1, 22)

    {:ok, {_filename, binary}} =
      %Elixlsx.Workbook{sheets: [sheet]}
      |> Elixlsx.write_to_memory("export.xlsx")

    binary
  end

  defp xlsx_raw_rows(row, xlsx_columns, children_key, xlsx_child_columns, has_children) do
    parent_cells = xlsx_parent_cells(row, xlsx_columns)

    if has_children do
      xlsx_child_rows(row, children_key, xlsx_child_columns, parent_cells)
    else
      [parent_cells]
    end
  end

  defp xlsx_parent_cells(row, xlsx_columns) do
    Enum.map(xlsx_columns, fn col ->
      val = Map.get(row, col.key) || Map.get(row, Atom.to_string(col.key)) || ""
      xlsx_cell_value(val, col.type)
    end)
  end

  defp xlsx_child_rows(row, children_key, xlsx_child_columns, parent_cells) do
    children = Map.get(row, children_key) || Map.get(row, Atom.to_string(children_key)) || []

    case children do
      [] ->
        blank_children = List.duplicate("", length(xlsx_child_columns))
        [parent_cells ++ blank_children]

      xlsx_children when is_list(xlsx_children) ->
        Enum.map(xlsx_children, fn child ->
          parent_cells ++ xlsx_child_cells(child, xlsx_child_columns)
        end)
    end
  end

  defp xlsx_header_labels(header_columns) do
    Enum.map(header_columns, & &1.label)
  end

  defp xlsx_child_cells(child, xlsx_child_columns) do
    Enum.map(xlsx_child_columns, fn col ->
      val = Map.get(child, col.key) || Map.get(child, Atom.to_string(col.key)) || ""
      xlsx_cell_value(val, col.type)
    end)
  end

  defp style_xlsx_rows(raw_rows, striped?, stripe_color, separator) do
    last_idx = length(raw_rows) - 1

    raw_rows
    |> Enum.with_index()
    |> Enum.map(fn {cells, row_idx} ->
      last_in_group? = row_idx == last_idx

      Enum.map(cells, fn cell ->
        style =
          if(striped?, do: [bg_color: stripe_color], else: []) ++
            if(last_in_group?, do: [border: separator], else: [])

        case {cell, style} do
          {_, []} -> cell
          {val, props} when is_binary(val) -> [val | props]
          {val, props} when is_number(val) -> [val | props]
          _ -> cell
        end
      end)
    end)
  end

  defp xlsx_column_widths(all_rows) do
    all_rows
    |> Enum.reduce(%{}, fn row, acc ->
      row
      |> Stream.with_index(1)
      |> Enum.reduce(acc, fn {cell, idx}, width_acc ->
        Map.update(width_acc, idx, cell_width(cell), &max(&1, cell_width(cell)))
      end)
    end)
    |> Map.new(fn {idx, max_len} -> {idx, min(max_len + 3, 60)} end)
  end

  defp cell_width([val | _]) when is_binary(val), do: String.length(val)
  defp cell_width(val) when is_binary(val), do: String.length(val)
  defp cell_width(val) when is_number(val), do: val |> to_string() |> String.length()
  defp cell_width(_), do: 0

  defp xlsx_cell_value(val, :number) when is_binary(val) do
    case Float.parse(val) do
      {n, ""} -> n
      _ -> val
    end
  end

  defp xlsx_cell_value(val, :number) when is_number(val), do: val
  defp xlsx_cell_value(val, _type), do: to_string(val)

  # Parse compound `"<parent_id>:child:<idx>"` identifiers.
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

  # Build a child-cell change map keyed by the child's natural key fields
  # (e.g. %{"level" => 3}). The child is located in the rendered row by
  # array index, but the change sent to the server addresses it by key —
  # this matches the post-redesign update_cells contract and stays stable
  # across reorders.
  defp build_child_change(assigns, parent_id, child_index, field, value) do
    schema = assigns.schema
    children_key = schema.children_key
    key_fields = (schema && schema.child_key_fields) || []

    row = find_row(assigns.rows, parent_id)
    children = (row && Map.get(row, children_key)) || []
    child = Enum.at(children, child_index) || %{}
    child_key = build_child_key(child, key_fields)

    %{
      "id" => parent_id,
      "child_key" => child_key,
      "field" => field,
      "value" => value
    }
  end

  defp build_child_key(child, key_fields) when is_list(key_fields) and key_fields != [] do
    Map.new(key_fields, fn f ->
      {Atom.to_string(f), Map.get(child, f, Map.get(child, Atom.to_string(f)))}
    end)
  end

  defp build_child_key(_, _), do: %{}

  # --- Optimistic edit overlay ---

  defp apply_optimistic(optimistic_rows, optimistic) when optimistic == %{}, do: optimistic_rows

  defp apply_optimistic(optimistic_rows, optimistic) do
    Enum.map(optimistic_rows, fn row ->
      id = to_string(row_id(row))
      apply_optimistic_row(row, id, optimistic)
    end)
  end

  defp apply_optimistic_row(row, id, optimistic) do
    Enum.reduce(optimistic, row, fn
      {{^id, nil, field}, value}, acc ->
        put_cell(acc, field, value)

      {{^id, child_idx, field}, value}, acc when is_integer(child_idx) ->
        update_child(acc, child_idx, field, value)

      _, acc ->
        acc
    end)
  end

  defp put_cell(row, field, value) do
    cond do
      is_atom_key?(row, field) ->
        Map.put(row, String.to_existing_atom(field), value)

      map_key?(row, field) ->
        Map.put(row, field, value)

      true ->
        Map.put(row, field, value)
    end
  end

  defp is_atom_key?(row, field) when is_binary(field) do
    atom =
      try do
        String.to_existing_atom(field)
      rescue
        ArgumentError -> nil
      end

    atom && map_key?(row, atom)
  end

  defp map_key?(map, key) do
    case Map.fetch(map, key) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp update_child(row, idx, field, value) do
    children_key =
      case {Map.fetch(row, :proficiency_levels), Map.fetch(row, "proficiency_levels")} do
        {{:ok, _}, _} -> :proficiency_levels
        {_, {:ok, _}} -> "proficiency_levels"
        _ -> nil
      end

    case children_key && Map.get(row, children_key) do
      nil ->
        row

      children when is_list(children) ->
        updated =
          List.update_at(children, idx, fn child ->
            put_cell(child || %{}, field, value)
          end)

        Map.put(row, children_key, updated)

      _ ->
        row
    end
  end

  # --- Workbench presentation helpers ---

  defp active_artifact(%WorkbenchContext{active_artifact: artifact}), do: artifact
  defp active_artifact(_), do: nil

  defp artifact_for_table(%WorkbenchContext{artifacts: artifacts}, table_name) do
    Enum.find(artifacts, &(&1.table_name == table_name))
  end

  defp artifact_for_table(_, _), do: nil

  defp artifact_tab_label(artifact, fallback),
    do: WorkbenchPresenter.tab_label(artifact, fallback)

  defp artifact_tab_meta(artifact, count), do: WorkbenchPresenter.tab_meta(artifact, count)

  defp artifact_title(artifact, fallback), do: WorkbenchPresenter.title(artifact, fallback)
  defp artifact_subtitle(artifact, fallback), do: WorkbenchPresenter.subtitle(artifact, fallback)

  defp artifact_kind_label(nil, fallback), do: fallback
  defp artifact_kind_label(artifact, _fallback), do: WorkbenchPresenter.kind_label(artifact)

  defp artifact_metric_labels(nil, row_count), do: ["#{row_count} rows"]

  defp artifact_metric_labels(artifact, _row_count),
    do: WorkbenchPresenter.metric_labels(artifact)

  defp selection_noun(artifact, count), do: WorkbenchPresenter.selection_noun(artifact, count)
  defp artifact_surface(nil), do: :artifact_summary
  defp artifact_surface(artifact), do: WorkbenchPresenter.surface(artifact)

  defp surface_notice?(surface),
    do:
      surface in [
        :linked_artifacts,
        :role_candidate_picker,
        :conflict_review,
        :dedup_review,
        :gap_review
      ]

  defp surface_metrics(%WorkbenchContext.ArtifactSummary{metrics: metrics, row_count: row_count}) do
    Map.put(metrics || %{}, :rows, row_count || 0)
  end

  defp surface_metrics(_), do: %{}

  defp linked_artifact_summary(%WorkbenchContext.ArtifactSummary{linked: linked}) do
    labels =
      []
      |> maybe_linked_label("skill framework", linked[:linked_library_table])
      |> maybe_linked_label("role requirements", linked[:linked_role_table])
      |> maybe_linked_label("source upload", linked[:source_upload_id])
      |> maybe_linked_label("source libraries", linked[:source_library_ids])
      |> maybe_linked_label("source roles", linked[:source_role_profile_ids])

    case labels do
      [] -> "Related artifacts are available in the artifact strip."
      labels -> Enum.join(Enum.reverse(labels), ", ")
    end
  end

  defp linked_artifact_summary(_), do: "Related artifacts are available in the artifact strip."

  defp maybe_linked_label(labels, _label, value) when value in [nil, "", []], do: labels
  defp maybe_linked_label(labels, label, _value), do: [label | labels]

  # --- Tab strip helpers ---

  defp table_row_count(tables, name) when is_list(tables) do
    case Enum.find(tables, fn t -> t.name == name end) do
      nil -> 0
      %{row_count: n} -> n
      _ -> 0
    end
  end

  defp table_row_count(_, _), do: 0
end
