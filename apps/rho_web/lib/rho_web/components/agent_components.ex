defmodule RhoWeb.AgentComponents do
  @moduledoc """
  Agent sidebar, agent tree node, and agent pill bar components.
  """
  use Phoenix.Component

  import RhoWeb.CoreComponents

  attr(:agents, :map, required: true)
  attr(:selected_agent_id, :string, default: nil)

  def agent_sidebar(assigns) do
    assigns = assign(assigns, :roots, root_agents(assigns.agents))

    ~H"""
    <aside class="agent-sidebar">
      <div class="sidebar-header">
        <h3>Agents</h3>
        <.badge><%= map_size(@agents) %></.badge>
      </div>
      <div class="agent-tree">
        <.agent_node
          :for={agent <- @roots}
          agent={agent}
          agents={@agents}
          selected={@selected_agent_id == agent.agent_id}
          selected_agent_id={@selected_agent_id}
        />
      </div>
    </aside>
    """
  end

  attr(:agent, :map, required: true)
  attr(:agents, :map, required: true)
  attr(:selected, :boolean, default: false)
  attr(:selected_agent_id, :string, default: nil)

  def agent_node(assigns) do
    children = children(assigns.agents, assigns.agent.agent_id)
    assigns = assign(assigns, :children, children)

    ~H"""
    <div class={"agent-node #{if @selected, do: "selected", else: ""}"}>
      <div class="agent-node-row" phx-click="select_agent" phx-value-agent-id={@agent.agent_id}>
        <.status_dot status={@agent.status} />
        <span class="agent-role"><%= @agent.role %></span>
        <.badge :if={@agent.depth > 0} class="badge-depth">d<%= @agent.depth %></.badge>
        <span :if={@agent[:step]} class="agent-step">
          step <%= @agent.step %><span :if={@agent[:max_steps]}>/<%= @agent.max_steps %></span>
        </span>
      </div>
      <div :if={@children != []} class="agent-children">
        <.agent_node
          :for={child <- @children}
          agent={child}
          agents={@agents}
          selected={@selected_agent_id == child.agent_id}
          selected_agent_id={@selected_agent_id}
        />
      </div>
    </div>
    """
  end

  defp root_agents(agents) do
    # Roots are agents whose derived parent is not itself a known agent
    # (i.e. primaries, or orphans whose parent lives outside this view).
    known_ids = Map.keys(agents) |> MapSet.new()

    agents
    |> Map.values()
    |> Enum.filter(fn agent ->
      parent = Rho.Agent.Primary.parent_of(agent.agent_id)
      is_nil(parent) or not MapSet.member?(known_ids, parent)
    end)
    |> Enum.sort_by(& &1.agent_id)
  end

  defp children(agents, parent_id) do
    agents
    |> Map.values()
    |> Enum.filter(fn agent ->
      Rho.Agent.Primary.parent_of(agent.agent_id) == parent_id
    end)
    |> Enum.sort_by(& &1.agent_id)
  end
end
