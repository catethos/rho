defmodule RhoWeb.Workspaces.DataTable do
  @moduledoc """
  Workspace metadata for the DataTable (Skills Editor) panel.
  """
  use RhoWeb.Workspace

  @impl true
  def key, do: :data_table

  @impl true
  def label, do: "Skills Editor"

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
    %{
      table_state: ws_state,
      schema: (ws_state || %{})[:schema] || RhoWeb.DataTable.Schemas.skill_library(),
      streaming: shared.streaming,
      total_cost: shared.total_cost,
      session_id: shared.session_id
    }
  end

  @impl true
  def handle_info({:data_table_get_table, {caller_pid, ref}, filter}, ws_state, _context) do
    if ws_state do
      alias RhoWeb.Projections.DataTableProjection
      rows = ws_state.rows_map |> Map.values() |> DataTableProjection.filter_rows(filter)
      send(caller_pid, {ref, {:ok, rows}})
    else
      send(caller_pid, {ref, {:ok, []}})
    end

    {:noreply, ws_state}
  end

  def handle_info(_message, _ws_state, _context), do: :skip
end
