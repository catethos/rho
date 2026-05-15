defmodule RhoWeb.DataTableComponent do
  @moduledoc """
  LiveComponent for an interactive, schema-driven data table.

  Row state is owned by `Rho.Stdlib.DataTable.Server`; this component
  renders snapshots, edits cells, switches named table tabs, and can
  temporarily resurface the Workbench action hub over active artifacts.
  """
  use Phoenix.LiveComponent

  alias Rho.Stdlib.DataTable
  alias RhoWeb.DataTable.Artifacts
  alias RhoWeb.DataTable.Commands
  alias RhoWeb.DataTable.Export
  alias RhoWeb.DataTable.Optimistic
  alias RhoWeb.DataTable.RowComponents
  alias RhoWeb.DataTable.Rows
  alias RhoWeb.DataTable.Streams
  alias RhoWeb.DataTable.Tabs
  alias RhoWeb.WorkbenchActions
  alias RhoWeb.WorkbenchActionComponent

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
      |> assign_new(:agent_name, fn -> nil end)
      |> assign_new(:libraries, fn -> [] end)
      |> assign_new(:chat_mode, fn -> nil end)
      |> assign_new(:show_workbench_home?, fn -> false end)
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
      |> assign_new(:stream_page_size, fn -> Streams.default_page_size() end)

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

    effective_rows = Optimistic.apply(rows, optimistic)
    sorted_rows = Rows.sort(effective_rows, socket.assigns.sort_by, socket.assigns.sort_dir)
    grouped = Rows.group(sorted_rows, schema.group_by)

    # On first render (or first render with data), collapse all groups.
    collapsed =
      case socket.assigns.collapsed do
        :all_collapsed ->
          ids = Rows.collect_group_ids(grouped)
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
              :all_collapsed -> Rows.collect_group_ids(grouped)
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

    select_all_state = Rows.select_all_state(effective_rows, socket.assigns[:selected_ids])

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
    page_size = socket.assigns[:stream_page_size] || Streams.default_page_size()
    sort_key = {socket.assigns.sort_by, socket.assigns.sort_dir}

    hinted = expand_hint_to_group_ids(expand_hint)

    walk_leaf_groups(grouped, socket, fn group_id, rows, acc ->
      cond do
        group_streamed?(streamed, group_id) and rows_changed? ->
          # Already streamed and snapshot version bumped → refresh to
          # first window in the current sort.
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
          # Hinted-and-now-expanded → seed eagerly so the user sees the
          # rows on first render after the hint fires.
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

  defp group_id_for(category), do: Streams.group_id_for(category)
  defp group_id_for(category, cluster), do: Streams.group_id_for(category, cluster)

  @impl true
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

  def handle_event("navigate_to_library", %{"library-id" => library_id}, socket) do
    send(self(), {:navigate_to_library, library_id})
    {:noreply, socket}
  end

  def handle_event("candidates_done", _params, socket) do
    send(self(), {:role_candidates_done})
    {:noreply, socket}
  end

  def handle_event("open_save_dialog", _params, socket) do
    name = Artifacts.library_name_from_table(socket.assigns[:active_table])
    {:noreply, assign(socket, action_dialog: {:save, name})}
  end

  def handle_event("open_publish_dialog", _params, socket) do
    name = Artifacts.library_name_from_table(socket.assigns[:active_table])
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

    csv = Export.build_csv(rows, schema)
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

    xlsx_binary = Export.build_xlsx(rows, schema)
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

    {change, optimistic_key} =
      Commands.cell_change(socket.assigns.rows, socket.assigns.schema, id, field, value)

    # Optimistic overlay so the UI updates immediately even if the
    # server round-trip and invalidation event haven't landed yet.
    optimistic = Map.put(socket.assigns.optimistic_edits, optimistic_key, value)

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

    {change, optimistic_key} = Commands.conflict_resolution_change(id, resolution)
    optimistic = Map.put(socket.assigns.optimistic_edits, optimistic_key, resolution)

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
          Rows.collect_group_ids(grouped) |> MapSet.delete(group_id)

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

  # --- Add / Delete rows ---

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
    sorted = Rows.sort(rows, new_sort_by, new_sort_dir)
    grouped = Rows.group(sorted, socket.assigns.schema.group_by)

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

  defp more_pages?(streamed, group_id), do: Streams.more_pages?(streamed, group_id)

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

  # Phase E: stream_delete the parent (and its panel item, if any) on
  # row delete. The server-side invalidation will eventually re-seed
  # the group, but this drops the row from the DOM immediately.
  defp optimistic_stream_delete(socket, id) do
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

  # First-expand population: if this group hasn't been streamed yet,
  # seed its first window from the current row list.
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
        # Parent group was never streamed → nothing to update; the
        # parent row isn't in DOM yet anyway.
        socket

      true ->
        # Re-seed the affected leaf group's stream so the panel item
        # lands right after its parent. `stream_insert/4` only supports
        # numeric/at positions, not "after dom_id X", so a full re-seed
        # of this single group is the simplest way to keep parent +
        # panel adjacent.
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["dt-panel", @class]}>
      <% active_artifact = Artifacts.active_artifact(@workbench_context) %>
      <% display_table_order = Tabs.display_order(@table_order, @tables) %>
      <% natural_home? = Artifacts.workbench_home?(@workbench_context, @table_order, @active_table, @rows) %>
      <% home? = natural_home? || @show_workbench_home? %>
      <%= if @error do %>
        <div class="dt-error-banner">
          <strong>Data table unavailable:</strong> <%= inspect(@error) %>
          <div class="dt-error-hint">The per-session table server is not running. Reload the page or regenerate the data.</div>
        </div>
      <% end %>

      <%= if home? do %>
        <WorkbenchActionComponent.workbench_home
          actions={WorkbenchActions.home_actions()}
          agent_name={@agent_name}
          libraries={@libraries}
          chat_mode={@chat_mode}
          return_available?={!natural_home?}
          target={@myself}
        />
      <% else %>
      <%= if length(display_table_order) > 1 do %>
        <div class="dt-tab-strip">
          <%= for name <- display_table_order do %>
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
                :if={name != "main"}
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

      <%= if MapSet.size(@selected_ids) > 0 do %>
        <div class="dt-selection-bar">
          <span class="dt-selection-count">
            <%= MapSet.size(@selected_ids) %> <%= Artifacts.selection_noun(active_artifact, MapSet.size(@selected_ids)) %> selected
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
          <div class="dt-artifact-kicker"><%= Artifacts.kind_label(active_artifact, @schema.title) %></div>
          <h2 class="dt-title"><%= Artifacts.title(active_artifact, @schema.title) %></h2>
          <div class="dt-artifact-subtitle">
            <span><%= Artifacts.subtitle(active_artifact, @mode_label) %></span>
            <span :if={active_artifact && active_artifact.source_label} class="dt-artifact-source">
              <%= active_artifact.source_label %>
            </span>
          </div>
          <div class="dt-metric-strip">
            <span :for={metric <- Artifacts.metric_labels(active_artifact, length(@rows))} class="dt-metric-pill">
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
            type="button"
            class="dt-action-btn dt-actions-hub-btn"
            phx-click="show_workbench_home"
            phx-target={@myself}
            title="Show Workbench actions"
          >
            Actions
          </button>
          <button
            :if={Artifacts.candidates_view?(@view_key, @active_table)}
            type="button"
            class="dt-action-btn dt-candidates-done-btn"
            phx-click="candidates_done"
            phx-target={@myself}
            title="Use the checked rows to seed a new framework"
          >
            ✓ Done — Seed Framework
          </button>
          <button
            :if={Artifacts.library_view?(@view_key, @active_table)}
            type="button"
            class="dt-action-btn dt-save-btn"
            phx-click="open_save_dialog"
            phx-target={@myself}
            title="Save to library"
          >
            Save
          </button>
          <button
            :if={Artifacts.library_view?(@view_key, @active_table)}
            type="button"
            class="dt-action-btn dt-publish-btn"
            phx-click="open_publish_dialog"
            phx-target={@myself}
            title="Publish as immutable version"
          >
            Publish
          </button>
          <button
            :if={Artifacts.library_view?(@view_key, @active_table)}
            type="button"
            class="dt-action-btn dt-fork-btn"
            phx-click="fork_library"
            phx-target={@myself}
            title="Fork as new library"
          >
            Fork
          </button>
          <button
            :if={Artifacts.library_view?(@view_key, @active_table)}
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
        surface={Artifacts.surface(active_artifact)}
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
                <span class="dt-group-count" phx-click="toggle_group" phx-target={@myself} phx-value-group={group_id}><%= Rows.count_nested_rows(children) %> rows</span>
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
                    <RowComponents.add_row_in_group myself={@myself} group_by={group_by} group_label={group_label} sub_label={nil} />
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
                          <RowComponents.add_row_in_group myself={@myself} group_by={group_by} group_label={group_label} sub_label={sub_label} />
                        </div>
                      </div>
                    <% end %>
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
      <% end %>
    </div>
    """
  end

  attr(:artifact, :any, default: nil)
  attr(:surface, :atom, default: :artifact_summary)
  attr(:selected_count, :integer, default: 0)

  defp workbench_surface_notice(assigns) do
    assigns = assign(assigns, :metrics, Artifacts.surface_metrics(assigns.artifact))

    ~H"""
    <div :if={Artifacts.surface_notice?(@surface)} class={"dt-surface-notice dt-surface-#{@surface}"}>
      <%= case @surface do %>
        <% :linked_artifacts -> %>
          <div class="dt-surface-copy">
            <span class="dt-surface-label">Linked artifacts</span>
            <strong>Review the related workbench artifacts together</strong>
            <span><%= Artifacts.linked_summary(@artifact) %></span>
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
              <RowComponents.proficiency_panel_row
                dom_id={dom_id}
                row={row}
                children_key={@children_key}
                editing={@editing}
                myself={@myself}
                panel_colspan={@panel_colspan}
              />
            <% _ -> %>
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
      </tbody>
    </table>
    """
  end

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

  # --- Row lookup helpers ---

  defp find_row(row_entries, id) do
    Enum.find(row_entries, fn row -> to_string(Rows.row_id(row)) == id end)
  end

  # --- Collapsed state helpers ---

  defp collapsed?(collapsed, id), do: Streams.collapsed?(collapsed, id)

  defp find_column(schema, field_name) when is_binary(field_name) do
    Enum.find(schema.columns, &(Atom.to_string(&1.key) == field_name)) ||
      Enum.find(schema.child_columns || [], &(Atom.to_string(&1.key) == field_name))
  end

  defp find_column(_, _), do: nil

  defp slug(text), do: Streams.slug_fragment(text)

  defp clamp_suggest_n(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> clamp_suggest_n(n)
      :error -> 5
    end
  end

  defp clamp_suggest_n(n) when is_integer(n), do: n |> max(1) |> min(10)
  defp clamp_suggest_n(_), do: 5

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
end
