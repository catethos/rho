defmodule RhoWeb.DataTableComponent do
  @moduledoc """
  LiveComponent for an interactive, schema-driven data table.

  Row state is owned by `Rho.Stdlib.DataTable.Server`; this component
  renders snapshots, edits cells, switches named table tabs, and can
  temporarily resurface the Workbench action hub over active artifacts.
  """
  use Phoenix.LiveComponent

  alias RhoWeb.DataTable.Artifacts
  alias RhoWeb.DataTable.EventHandlers
  alias RhoWeb.DataTable.Optimistic
  alias RhoWeb.DataTable.Rows
  alias RhoWeb.DataTable.StreamLifecycle
  alias RhoWeb.DataTable.Streams
  alias RhoWeb.DataTableArtifactHeaderComponent
  alias RhoWeb.DataTableDialogsComponent
  alias RhoWeb.DataTableGridComponent
  alias RhoWeb.DataTableSelectionBarComponent
  alias RhoWeb.DataTableSurfaceNoticeComponent
  alias RhoWeb.DataTableTabsComponent
  alias RhoWeb.WorkbenchActions
  alias RhoWeb.WorkbenchActionComponent
  alias RhoWeb.WorkbenchDisplay

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
      |> assign_new(:workbench_display, fn -> nil end)
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

    {collapsed, socket} =
      StreamLifecycle.apply_expand_groups(assigns, collapsed, grouped, socket)

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
      StreamLifecycle.seed_visible_streams(
        socket,
        grouped,
        schema,
        collapsed,
        StreamLifecycle.expand_groups_hint(assigns),
        rows_changed?
      )

    {:ok, socket}
  end

  @impl true
  def handle_event(event, params, socket), do: EventHandlers.handle_event(event, params, socket)

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["dt-panel", @class]}>
      <% active_artifact = Artifacts.active_artifact(@workbench_context) %>
      <% natural_home? = Artifacts.workbench_home?(@workbench_context, @table_order, @active_table, @rows) %>
      <% data_state = %{table_order: @table_order, tables: @tables, active_table: @active_table} %>
      <% display = WorkbenchDisplay.for_render(@workbench_display, data_state, natural_home?) %>
      <% home? = WorkbenchDisplay.home?(display, data_state) %>
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
          return_available?={WorkbenchDisplay.return_available?(display, data_state)}
          target={@myself}
        />
      <% else %>
      <DataTableTabsComponent.tabs
        active_table={@active_table}
        myself={@myself}
        table_order={@table_order}
        tables={@tables}
        workbench_context={@workbench_context}
      />

      <DataTableSelectionBarComponent.selection_bar
        active_artifact={active_artifact}
        myself={@myself}
        selected_ids={@selected_ids}
      />

      <DataTableArtifactHeaderComponent.header
        active_artifact={active_artifact}
        active_table={@active_table}
        export_menu_open={@export_menu_open}
        flash_message={@flash_message}
        mode_label={@mode_label}
        myself={@myself}
        rows={@rows}
        schema={@schema}
        streaming={@streaming}
        total_cost={@total_cost}
        view_key={@view_key}
      />

      <DataTableSurfaceNoticeComponent.notice
        artifact={active_artifact}
        surface={Artifacts.surface(active_artifact)}
        selected_count={MapSet.size(@selected_ids)}
      />

      <DataTableDialogsComponent.dialogs action_dialog={@action_dialog} myself={@myself} />

      <DataTableGridComponent.grid
        collapsed={@collapsed}
        confirm_delete={@confirm_delete}
        editing={@editing}
        editing_group={@editing_group}
        group_to_stream={@_group_to_stream}
        grouped={@grouped}
        metadata={@metadata}
        myself={@myself}
        schema={@schema}
        select_all_state={@select_all_state}
        selected_ids={@selected_ids}
        sort_by={@sort_by}
        sort_dir={@sort_dir}
        streamed_groups={@_streamed_groups}
        streams={Map.get(assigns, :streams, %{})}
      />
      <% end %>
    </div>
    """
  end
end
