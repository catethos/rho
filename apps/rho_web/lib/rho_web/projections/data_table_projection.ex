defmodule RhoWeb.Projections.DataTableProjection do
  @moduledoc """
  Stub projection for the DataTable workspace.

  After the pure-renderer LiveView rewrite, the data table projection
  no longer owns row state. Rows are canonical on
  `Rho.Stdlib.DataTable.Server`, fetched by the LiveView via snapshot
  calls in `SessionLive.handle_info/2`, and pushed into workspace state
  via `ws_state_update`.

  This module still exists so the `RhoWeb.Workspace` framework wiring
  in `RhoWeb.Workspaces.DataTable` has a projection module to point at.
  It declares an empty handler set (reducer never matches), returns a
  default snapshot-cache shape from `init/0`, and no-ops on `reduce/2`.
  """

  @behaviour RhoWeb.Projection

  @doc "Default workspace state — a snapshot cache populated by SessionLive."
  @impl true
  def init do
    %{
      tables: [],
      table_order: [],
      active_table: "main",
      active_snapshot: nil,
      active_version: nil,
      view_key: nil,
      mode_label: nil,
      metadata: %{},
      error: nil,
      flash_message: nil,
      selections: %{}
    }
  end

  @doc "This stub does not react to any events — state is updated via `ws_state_update`."
  @impl true
  def handles?(_kind), do: false

  @impl true
  def reduce(state, _signal), do: state
end
