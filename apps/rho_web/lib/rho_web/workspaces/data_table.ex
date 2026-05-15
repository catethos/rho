defmodule RhoWeb.Workspaces.DataTable do
  @moduledoc """
  Workspace metadata for the DataTable (Skills Editor) panel.

  Holds a **snapshot cache** rather than a row reducer — the actual row
  state lives in `Rho.Stdlib.DataTable.Server` and is fetched by
  `RhoWeb.SessionLive` via `handle_info/2` on invalidation events.
  """
  use RhoWeb.Workspace

  alias Rho.Stdlib.DataTable.WorkbenchContext
  alias RhoWeb.DataTable.Schemas
  alias RhoWeb.WorkbenchDisplay

  @impl true
  def key, do: :data_table

  @impl true
  def label, do: "Workbench"

  @impl true
  def icon, do: "table"

  @impl true
  def auto_open?, do: true

  @impl true
  def default_surface, do: :overlay

  @impl true
  def projection, do: RhoWeb.Projections.DataTableProjection

  @impl true
  def component, do: RhoWeb.DataTableComponent

  @impl true
  def component_assigns(ws_state, shared) do
    state = ws_state || RhoWeb.Projections.DataTableProjection.init()

    snapshot = state.active_snapshot
    rows = (snapshot && snapshot.rows) || []

    schema = Schemas.resolve(state.view_key, state.active_table)

    selected_ids =
      state
      |> Map.get(:selections, %{})
      |> Map.get(state.active_table, MapSet.new())

    workbench_context =
      WorkbenchContext.build(%{
        tables: state.tables,
        table_order: state.table_order,
        active_table: state.active_table,
        active_snapshot: state.active_snapshot,
        selections: Map.get(state, :selections, %{}),
        metadata: state.metadata || %{},
        view_key: state.view_key
      })

    %{
      rows: rows,
      schema: schema,
      workbench_context: workbench_context,
      tables: state.tables,
      table_order: state.table_order,
      active_table: state.active_table,
      view_key: state.view_key,
      mode_label: state.mode_label,
      metadata: state.metadata || %{},
      error: state.error,
      flash_message: state[:flash_message],
      version: state.active_version,
      streaming: shared.streaming,
      total_cost: shared.total_cost,
      session_id: shared.session_id,
      agent_name: Map.get(shared, :active_agent_name),
      libraries: Map.get(shared, :workbench_libraries, []),
      chat_mode: Map.get(shared, :chat_mode),
      workbench_display:
        Map.get(shared, :workbench_display) || WorkbenchDisplay.from_data_state(state),
      selected_ids: selected_ids
    }
  end

  @impl true
  def handle_info(_message, _ws_state, _context), do: :skip
end
