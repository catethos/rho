defmodule RhoWeb.CommandPaletteComponent do
  @moduledoc """
  Command palette (Cmd+K) — a searchable modal for workspace and shell actions.
  Receives available actions from the parent and filters locally via substring match.
  """
  use Phoenix.LiveComponent

  @impl true
  def mount(socket) do
    {:ok, assign(socket, query: "", filtered_actions: [])}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    actions = build_actions(assigns)
    filtered = filter_actions(actions, socket.assigns.query)
    {:ok, assign(socket, actions: actions, filtered_actions: filtered)}
  end

  @impl true
  def handle_event("filter", %{"query" => query}, socket) do
    filtered = filter_actions(socket.assigns.actions, query)
    {:noreply, assign(socket, query: query, filtered_actions: filtered)}
  end

  def handle_event("execute", %{"action" => action_id}, socket) do
    send(self(), {:command_palette_action, action_id})
    {:noreply, assign(socket, query: "")}
  end

  def handle_event("close", _params, socket) do
    send(self(), :close_command_palette)
    {:noreply, assign(socket, query: "")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="command-palette-wrapper">
      <div
        :if={@open}
        id="command-palette"
        class="command-palette-overlay"
        phx-click="close"
        phx-target={@myself}
      >
        <div class="command-palette" phx-click-away="close" phx-target={@myself}>
          <div class="command-palette-input-row">
            <span class="command-palette-icon">&#8984;K</span>
            <input
              id="command-palette-input"
              type="text"
              class="command-palette-input"
              placeholder="Type a command..."
              value={@query}
              phx-keyup="filter"
              phx-target={@myself}
              phx-hook="AutoFocus"
              autocomplete="off"
            />
          </div>
          <div class="command-palette-results">
            <button
              :for={action <- @filtered_actions}
              class="command-palette-item"
              phx-click="execute"
              phx-target={@myself}
              phx-value-action={action.id}
            >
              <span class="command-palette-item-label"><%= action.label %></span>
              <span :if={action[:shortcut]} class="command-palette-item-shortcut"><%= action.shortcut %></span>
            </button>
            <div :if={@filtered_actions == []} class="command-palette-empty">
              No matching commands
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp build_actions(assigns) do
    workspace_actions =
      Enum.map(assigns.workspaces, fn {key, ws} ->
        %{id: "open_workspace:#{key}", label: "Open #{ws.label}", category: :workspace}
      end)

    chat_action =
      if assigns.shell.chat_mode == :expanded do
        [%{id: "toggle_chat", label: "Hide Chat Panel", category: :shell}]
      else
        [%{id: "toggle_chat", label: "Show Chat Panel", category: :shell}]
      end

    focus_action =
      if assigns.shell.focus_workspace_id do
        [%{id: "exit_focus", label: "Exit Focus Mode", shortcut: "Esc", category: :shell}]
      else
        [%{id: "enter_focus", label: "Focus Workspace (fullscreen)", shortcut: "Esc", category: :shell}]
      end

    thread_actions =
      Enum.map(assigns.threads, fn thread ->
        %{id: "switch_thread:#{thread["id"]}", label: "Switch to thread: #{thread["name"]}", category: :thread}
      end)

    workspace_actions ++ chat_action ++ focus_action ++ thread_actions
  end

  defp filter_actions(actions, "") do
    actions
  end

  defp filter_actions(actions, query) do
    q = String.downcase(query)

    Enum.filter(actions, fn action ->
      String.contains?(String.downcase(action.label), q)
    end)
  end
end
