defmodule RhoWeb.AppLive.WorkspaceChromeComponents do
  @moduledoc """
  Workspace chrome and debug render components for `RhoWeb.AppLive`.
  """
  use Phoenix.Component

  alias RhoWeb.Session.SessionCore

  attr(:workspaces, :map, required: true)
  attr(:active, :atom, default: nil)
  attr(:available, :map, default: %{})
  attr(:shell, :map, required: true)
  attr(:pending, :boolean, default: false)

  def workspace_tab_bar(assigns) do
    chat_expanded = assigns.shell.chat_mode == :expanded
    assigns = assign(assigns, :chat_expanded, chat_expanded)

    ~H"""
    <div class="workspace-tab-bar">
      <div class="workspace-tabs">
        <button
          :for={{key, ws} <- @workspaces}
          class={"workspace-tab #{if @active == key, do: "active", else: ""}"}
          phx-click="switch_workspace"
          phx-value-workspace={key}
        >
          <span class="workspace-tab-label"><%= ws.label() %></span>
          <% chrome = @shell.workspaces[key] %>
          <span :if={chrome && chrome.pulse} class="workspace-tab-activity">
            <span class="workspace-tab-pulse"></span>
          </span>
          <span :if={chrome && chrome.unseen_count > 0} class="workspace-tab-badge">
            <%= chrome.unseen_count %>
          </span>
          <span
            class="workspace-tab-close"
            phx-click="close_workspace"
            phx-value-workspace={key}
          >
            &times;
          </span>
        </button>
      </div>

      <div class="workspace-tab-actions">
        <button
          class={"workspace-tab-toggle-chat #{if @chat_expanded, do: "active", else: ""}"}
          phx-click="toggle_chat"
          title={if @chat_expanded, do: "Hide chat", else: "Show chat"}
        >
          Chat
        </button>

        <div :if={map_size(@available) > 0} class="workspace-add-picker">
          <button class="workspace-add-btn" phx-click={Phoenix.LiveView.JS.toggle(to: "#workspace-picker-dropdown")}>
            +
          </button>
          <div id="workspace-picker-dropdown" class="workspace-picker-dropdown" style="display: none;">
            <button
              :for={{key, ws} <- @available}
              class="workspace-picker-item"
              phx-click="add_workspace"
              phx-value-workspace={key}
            >
              <%= ws.label() %>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:key, :atom, required: true)
  attr(:label, :string, required: true)
  attr(:ws_mod, :any, required: true)
  attr(:ws_state, :map, default: nil)
  attr(:shared_ws_assigns, :map, required: true)

  def workspace_overlay(assigns) do
    overlay_assigns =
      assigns.ws_mod.component_assigns(assigns.ws_state, assigns.shared_ws_assigns)

    assigns = assign(assigns, :overlay_assigns, overlay_assigns)

    ~H"""
    <div class="workspace-overlay is-open">
      <div class="workspace-overlay-header">
        <span class="workspace-overlay-title"><%= @label %></span>
        <div class="workspace-overlay-actions">
          <button
            class="workspace-overlay-btn pin-btn"
            phx-click="pin_workspace"
            phx-value-workspace={@key}
            title="Pin to tab bar"
          >
            Pin
          </button>
          <button
            class="workspace-overlay-close"
            phx-click="dismiss_overlay"
            phx-value-workspace={@key}
            title="Dismiss"
          >
            &times;
          </button>
        </div>
      </div>
      <div class="workspace-overlay-body">
        <.live_component
          :if={@ws_state}
          module={@ws_mod.component()}
          id={"overlay-#{@key}"}
          class="active"
          {@overlay_assigns}
        />
      </div>
    </div>
    """
  end

  attr(:projections, :map, required: true)
  attr(:active_agent_id, :string, default: nil)
  attr(:session_id, :string, default: nil)

  def debug_panel(assigns) do
    active_id = assigns.active_agent_id || SessionCore.primary_agent_id(assigns.session_id)
    projection = Map.get(assigns.projections, active_id)

    conversation =
      if assigns.session_id do
        Rho.Conversation.get_by_session(assigns.session_id)
      end

    thread = conversation && Rho.Conversation.active_thread(conversation["id"])

    assigns =
      assigns
      |> assign(:projection, projection)
      |> assign(:debug_agent_id, active_id)
      |> assign(:debug_conversation, conversation)
      |> assign(:debug_thread, thread)
      |> assign(:debug_command, debug_command(conversation, assigns.session_id))

    ~H"""
    <div class="debug-panel">
      <div class="debug-header">
        <h3>Debug: LLM Context</h3>
        <span :if={@projection} class="debug-meta">
          <%= @projection.raw_message_count %> messages, <%= @projection.raw_tool_count %> tools, step <%= @projection.step || "?" %>
        </span>
      </div>
      <div class="debug-body">
        <div :if={@debug_conversation} class="debug-section">
          <div class="debug-section-title">Trace</div>
          <div class="debug-tools-list">
            <span class="debug-tool-badge"><%= @debug_conversation["id"] %></span>
            <span :if={@debug_thread} class="debug-tool-badge"><%= @debug_thread["id"] %></span>
            <span :if={@debug_thread} class="debug-tool-badge"><%= @debug_thread["tape_name"] %></span>
          </div>
          <pre class="debug-msg-content"><%= @debug_command %></pre>
        </div>

        <%= if @projection do %>
          <div class="debug-section">
            <div class="debug-section-title">Tools (<%= length(@projection.tools) %>)</div>
            <div class="debug-tools-list">
              <span :for={tool <- @projection.tools} class="debug-tool-badge"><%= tool %></span>
            </div>
          </div>

          <div class="debug-section">
            <div class="debug-section-title">Context Messages (<%= length(@projection.context) %>)</div>
            <div class="debug-messages">
              <div :for={{msg, idx} <- Enum.with_index(@projection.context)} class={"debug-msg debug-msg-#{msg.role}"}>
                <div class="debug-msg-header">
                  <span class={"debug-msg-role debug-role-#{msg.role}"}><%= msg.role %></span>
                  <span class="debug-msg-idx">#<%= idx %></span>
                  <span :if={msg.cache_control} class="debug-msg-cache">cached</span>
                </div>
                <details class="debug-msg-details" open={String.length(debug_content_string(msg.content)) <= 5000}>
                  <summary class="debug-msg-summary"><%= String.length(debug_content_string(msg.content)) %> chars</summary>
                  <pre class="debug-msg-content"><%= debug_content_string(msg.content) %></pre>
                </details>
              </div>
            </div>
          </div>
        <% else %>
          <div class="debug-empty">No projection data yet. Send a message to see the LLM context.</div>
        <% end %>
      </div>
    </div>
    """
  end

  def debug_content_string(content) when is_binary(content) do
    content
  end

  def debug_content_string(content) do
    inspect(content, limit: :infinity)
  end

  def debug_command(%{"id" => conversation_id}, _session_id) do
    "mix rho.debug #{conversation_id}"
  end

  def debug_command(nil, session_id) when is_binary(session_id) do
    "mix rho.debug #{session_id}"
  end

  def debug_command(_conversation, _session_id) do
    "mix rho.debug <ref>"
  end
end
