defmodule RhoWeb.AgentDrawerComponent do
  @moduledoc """
  Stateful LiveComponent for the agent detail drawer.
  Owns lazy tape loading and has its own mini-chat input.
  """
  use Phoenix.LiveComponent

  import RhoWeb.CoreComponents

  @impl true
  def mount(socket) do
    {:ok, assign(socket, tape_entries: [], tape_loaded_for: nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Reload tape when the selected agent changes
    agent = assigns[:agent]
    agent_id = agent && agent.agent_id

    socket =
      if agent && socket.assigns.tape_loaded_for != agent_id do
        load_tape(socket, agent)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={"agent-drawer #{if @open, do: "open", else: ""}"}>
      <div :if={@open && @agent} class="drawer-content">
        <div class="drawer-header">
          <div class="drawer-title">
            <.status_dot status={@agent.status} />
            <h3><%= @agent.role %></h3>
            <.badge class="badge-agent"><%= @agent.agent_id %></.badge>
          </div>
          <button class="drawer-close" phx-click="close_drawer">×</button>
        </div>

        <div class="drawer-meta">
          <div class="meta-row">
            <span class="meta-label">Depth</span>
            <span><%= @agent.depth %></span>
          </div>
          <div :if={@agent[:capabilities] != []} class="meta-row">
            <span class="meta-label">Capabilities</span>
            <span><%= Enum.join(@agent.capabilities, ", ") %></span>
          </div>
          <div :if={@agent[:model]} class="meta-row">
            <span class="meta-label">Model</span>
            <span><%= @agent.model %></span>
          </div>
        </div>

        <div class="drawer-tape">
          <h4>Tape</h4>
          <div class="tape-entries">
            <div :for={entry <- @tape_entries} class={"tape-entry tape-#{entry.type}"}>
              <span class="tape-type"><%= entry.type %></span>
              <span class="tape-content"><%= truncate(entry.content, 300) %></span>
            </div>
            <div :if={@tape_entries == []} class="tape-empty">No tape entries</div>
          </div>
        </div>
      </div>
    </div>
    """
  end


  defp load_tape(socket, agent) do
    memory_mod = Rho.Config.memory_module()

    tape_name =
      case Rho.Agent.Worker.whereis(agent.agent_id) do
        nil ->
          # Worker stopped (e.g. after await_task) — get tape_name from registry
          case Rho.Agent.Registry.get(agent.agent_id) do
            %{memory_ref: ref} when is_binary(ref) -> ref
            _ -> nil
          end

        pid ->
          info = Rho.Agent.Worker.info(pid)
          info.tape_name
      end

    tape_entries =
      if tape_name do
        memory_mod.history(tape_name)
        |> Enum.map(fn entry ->
          %{type: entry[:role] || :unknown, content: entry[:content] || inspect(entry)}
        end)
      else
        []
      end

    socket
    |> assign(:tape_entries, tape_entries)
    |> assign(:tape_loaded_for, agent.agent_id)
  rescue
    e ->
      require Logger
      Logger.warning("Failed to load tape for #{agent.agent_id}: #{inspect(e)}")

      socket
      |> assign(:tape_entries, [])
      |> assign(:tape_loaded_for, agent.agent_id)
  end

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max) <> "…"
  end
  defp truncate(text, _max) when is_binary(text), do: text
  defp truncate(other, _max), do: inspect(other)
end
