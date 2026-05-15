defmodule RhoWeb.AppLive.WorkbenchDisplayState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2]

  alias RhoWeb.Projections.DataTableProjection
  alias RhoWeb.WorkbenchDisplay

  def initial_display do
    WorkbenchDisplay.from_data_state(DataTableProjection.init())
  end

  def initial_assigns(socket) do
    assign(socket,
      workbench_home_open?: false,
      workbench_display: initial_display()
    )
  end

  def shared_assigns(assigns, opts) do
    %{
      session_id: assigns.session_id,
      agents: assigns.agents,
      active_agent_name: Keyword.fetch!(opts, :active_agent_name),
      workbench_libraries: Keyword.fetch!(opts, :workbench_libraries),
      chat_mode: Keyword.fetch!(opts, :chat_mode),
      workbench_home_open?: assigns.workbench_home_open?,
      workbench_display: assigns.workbench_display,
      streaming: Keyword.fetch!(opts, :streaming),
      total_cost: assigns.total_cost
    }
  end

  def put_home(socket, true), do: WorkbenchDisplay.show_home(socket)
  def put_home(socket, false), do: WorkbenchDisplay.hide_home(socket)

  def put_table(socket, table_name), do: WorkbenchDisplay.show_table(socket, table_name)
end
