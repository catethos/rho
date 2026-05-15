defmodule RhoWeb.AppLive.AgentEvents do
  @moduledoc """
  Event handlers for AppLive agent lifecycle and tab interactions.
  """

  import Phoenix.Component, only: [assign: 3]

  alias RhoWeb.AppLive
  alias RhoWeb.Session.SessionCore
  alias RhoWeb.Session.Welcome

  def handle_event("select_tab", %{"agent-id" => agent_id}, socket) do
    {:noreply, assign(socket, :active_agent_id, agent_id)}
  end

  def handle_event("select_agent", %{"agent-id" => agent_id}, socket) do
    socket = socket |> assign(:selected_agent_id, agent_id) |> assign(:drawer_open, true)
    {:noreply, socket}
  end

  def handle_event("toggle_new_chat", _params, socket) do
    {:noreply, assign(socket, :show_new_chat, !socket.assigns.show_new_chat)}
  end

  def handle_event("create_agent", %{"role" => role} = params, socket) do
    {sid, socket} = ensure_agent_session(socket)
    parent_id = parent_agent_id(sid, params)
    agent_id = Rho.Agent.Primary.new_agent_id(parent_id)
    role_atom = role_atom(role)

    workspace = AppLive.user_workspace(socket)
    memory_mod = Rho.Config.tape_module()
    agent_ref = memory_mod.memory_ref(agent_id, workspace)
    memory_mod.bootstrap(agent_ref)

    {:ok, _pid} =
      Rho.Agent.Supervisor.start_worker(
        agent_id: agent_id,
        session_id: sid,
        workspace: workspace,
        agent_name: role_atom,
        role: role_atom,
        tape_ref: agent_ref,
        user_id: get_in(socket.assigns, [:current_user, Access.key(:id)]),
        organization_id: get_in(socket.assigns, [:current_organization, Access.key(:id)])
      )

    agent_entry = agent_entry(agent_id, sid, role_atom)

    socket =
      socket
      |> assign(:show_new_chat, false)
      |> assign(:active_agent_id, agent_id)
      |> assign(:agents, Map.put(socket.assigns.agents, agent_id, agent_entry))
      |> assign(:agent_tab_order, socket.assigns.agent_tab_order ++ [agent_id])
      |> assign(:agent_messages, Map.put_new(socket.assigns.agent_messages, agent_id, []))
      |> Welcome.render_for_new_agent(agent_id)

    {:noreply, socket}
  end

  def handle_event("remove_agent", %{"agent-id" => agent_id}, socket) do
    primary_id = SessionCore.primary_agent_id(socket.assigns.session_id)

    if agent_id == primary_id do
      {:noreply, socket}
    else
      stop_worker(agent_id)
      Rho.Agent.Registry.unregister(agent_id)

      {new_tab_order, new_agents, active} =
        remove_agent_state(socket.assigns, agent_id, primary_id)

      socket =
        socket
        |> assign(:agent_tab_order, new_tab_order)
        |> assign(:agents, new_agents)
        |> assign(:active_agent_id, active)

      {:noreply, socket}
    end
  end

  def handle_event("stop_session", _params, socket) do
    if socket.assigns.session_id do
      Rho.Agent.Primary.stop(socket.assigns.session_id)
    end

    {:noreply, socket}
  end

  def parent_agent_id(sid, params) do
    case params["parent_id"] do
      nil -> Rho.Agent.Primary.agent_id(sid)
      "" -> sid
      id -> id
    end
  end

  def role_atom(role) when is_binary(role) do
    String.to_existing_atom(role)
  rescue
    ArgumentError -> :worker
  end

  def role_atom(nil), do: :worker
  def role_atom(role) when is_atom(role), do: role
  def role_atom(_role), do: :worker

  def agent_entry(agent_id, sid, role_atom) do
    %{
      agent_id: agent_id,
      session_id: sid,
      role: role_atom,
      status: :idle,
      depth: 0,
      capabilities: [],
      model: nil,
      step: nil,
      max_steps: nil
    }
  end

  def remove_agent_state(assigns, agent_id, primary_id) do
    new_tab_order = Enum.reject(assigns.agent_tab_order, &(&1 == agent_id))
    new_agents = Map.delete(assigns.agents, agent_id)

    active =
      if assigns.active_agent_id == agent_id do
        primary_id
      else
        assigns.active_agent_id
      end

    {new_tab_order, new_agents, active}
  end

  defp ensure_agent_session(socket) do
    case socket.assigns.session_id do
      nil ->
        {new_sid, socket} = SessionCore.ensure_session(socket, nil)
        socket = SessionCore.subscribe_and_hydrate(socket, new_sid)
        {new_sid, socket}

      sid ->
        {sid, socket}
    end
  end

  defp stop_worker(agent_id) do
    case Rho.Agent.Worker.whereis(agent_id) do
      pid when is_pid(pid) -> GenServer.stop(pid, :normal, 5000)
      nil -> :ok
    end
  end
end
