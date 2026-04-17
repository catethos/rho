defmodule RhoWeb.SessionLive.LayoutComponents do
  @moduledoc """
  Private function components extracted from `RhoWeb.SessionLive`.

  Contains the session header, tab bar, workspace tab bar, workspace
  overlay, thread picker, chat side panel, new agent dialog, and debug
  panel render functions.
  """
  use Phoenix.Component

  import RhoWeb.CoreComponents
  import RhoWeb.ChatComponents

  alias RhoWeb.Session.SessionCore

  # --- Header component ---

  attr(:session_id, :string, default: nil)
  attr(:agents, :map, required: true)
  attr(:total_input_tokens, :integer, required: true)
  attr(:total_output_tokens, :integer, required: true)
  attr(:total_cost, :float, required: true)
  attr(:total_cached_tokens, :integer, required: true)
  attr(:total_reasoning_tokens, :integer, required: true)
  attr(:step_input_tokens, :integer, required: true)
  attr(:step_output_tokens, :integer, required: true)
  attr(:user_avatar, :string, default: nil)
  attr(:uploads, :any, required: true)
  attr(:debug_mode, :boolean, default: false)

  def session_header(assigns) do
    ~H"""
    <header class="session-header">
      <div class="header-left">
        <h1 class="header-title">Rho</h1>
        <span :if={@session_id} class="header-session-id"><%= truncate_id(@session_id) %></span>
        <.badge :if={map_size(@agents) > 0}>
          <%= map_size(@agents) %> agent<%= if map_size(@agents) != 1, do: "s" %>
        </.badge>
      </div>
      <div class="header-right">
        <span class="header-tokens" title="Total input / output tokens (last step input / output)">
          <%= format_tokens(@total_input_tokens) %> in / <%= format_tokens(@total_output_tokens) %> out
          <span :if={@step_input_tokens > 0} class="header-step-tokens">
            (step: <%= format_tokens(@step_input_tokens) %> in / <%= format_tokens(@step_output_tokens) %> out)
          </span>
        </span>
        <span :if={@total_cached_tokens > 0} class="header-tokens header-cached" title="Cached tokens">
          cached: <%= format_tokens(@total_cached_tokens) %>
        </span>
        <span :if={@total_reasoning_tokens > 0} class="header-tokens header-reasoning" title="Reasoning tokens">
          reasoning: <%= format_tokens(@total_reasoning_tokens) %>
        </span>
        <span :if={@total_cost > 0} class="header-cost">
          $<%= :erlang.float_to_binary(@total_cost / 1, decimals: 4) %>
        </span>
        <button class={"btn-new-agent #{if @debug_mode, do: "debug-active"}"} phx-click="toggle_debug" title="Toggle debug mode">
          Debug
        </button>
        <a :if={@session_id} href={"/observatory/#{@session_id}"} target="_blank"
          class="btn-new-agent" title="Open Observatory">
          Observatory
        </a>
        <button class="btn-new-agent" phx-click="toggle_new_agent" title="New agent">
          + Agent
        </button>
        <button :if={@session_id} class="btn-stop" phx-click="stop_session" title="Stop session">
          Stop
        </button>
        <form id="avatar-upload-form" phx-change="validate_upload" class="header-avatar-form">
          <label class="header-avatar" title="Click to upload avatar">
            <%= if @user_avatar do %>
              <img src={@user_avatar} class="header-avatar-img" />
            <% else %>
              <span class="header-avatar-placeholder">Y</span>
            <% end %>
            <.live_file_input upload={@uploads.avatar} class="sr-only" />
          </label>
        </form>
      </div>
    </header>
    """
  end

  # --- Tab bar ---

  attr(:agent_tab_order, :list, required: true)
  attr(:agents, :map, required: true)
  attr(:active_agent_id, :string, default: nil)
  attr(:inflight, :map, required: true)

  def tab_bar(assigns) do
    ~H"""
    <div class="chat-tab-bar" :if={length(@agent_tab_order) > 0}>
      <div
        :for={agent_id <- @agent_tab_order}
        class={"chat-tab #{if @active_agent_id == agent_id, do: "active", else: ""} #{if agent_stopped?(@agents, agent_id), do: "stopped", else: ""}"}
      >
        <button class="tab-select-btn" phx-click="select_tab" phx-value-agent-id={agent_id}>
          <.status_dot :if={@agents[agent_id]} status={@agents[agent_id].status} />
          <span class="tab-label"><%= tab_label(@agents, agent_id) %></span>
          <span :if={Map.has_key?(@inflight, agent_id)} class="tab-typing">...</span>
        </button>
        <button
          :if={!is_primary_tab?(agent_id)}
          class="tab-close-btn"
          phx-click="remove_agent"
          phx-value-agent-id={agent_id}
          title="Remove agent"
        >×</button>
      </div>
    </div>
    """
  end

  # --- Workspace tab bar ---

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

  # --- Workspace overlay ---

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
            ×
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

  # --- Thread picker ---

  attr(:threads, :list, required: true)
  attr(:active_thread_id, :string, default: nil)

  def thread_picker(assigns) do
    ~H"""
    <div :if={length(@threads) > 0} class="thread-picker">
      <div class="thread-picker-tabs">
        <div
          :for={thread <- @threads}
          class={"thread-tab #{if thread["id"] == @active_thread_id, do: "active", else: ""}"}
        >
          <button
            class="thread-tab-btn"
            phx-click="switch_thread"
            phx-value-thread_id={thread["id"]}
            title={thread["summary"] || thread["name"]}
          >
            <span class="thread-tab-label"><%= thread["name"] %></span>
          </button>
          <button
            :if={thread["id"] != "thread_main"}
            class="thread-tab-close"
            phx-click="close_thread"
            phx-value-thread_id={thread["id"]}
            title="Close thread"
          >
            ×
          </button>
        </div>
      </div>
      <button class="thread-new-btn" phx-click="new_blank_thread" title="New thread">
        +
      </button>
    </div>
    """
  end

  # --- Chat side panel ---

  attr(:chat_mode, :atom, default: :expanded)
  attr(:compact, :boolean, default: false)
  attr(:messages, :list, required: true)
  attr(:session_id, :string, required: true)
  attr(:inflight, :map, required: true)
  attr(:active_agent_id, :string, required: true)
  attr(:user_avatar, :string, default: nil)
  attr(:agent_avatar, :string, default: nil)
  attr(:pending, :boolean, default: false)
  attr(:agents, :map, required: true)
  attr(:agent_tab_order, :list, required: true)
  attr(:chat_status, :atom, default: :idle)
  attr(:uploads, :any, required: true)
  attr(:active_agent, :map, default: nil)
  attr(:connected, :boolean, default: true)
  attr(:threads, :list, default: [])
  attr(:active_thread_id, :string, default: nil)

  def chat_side_panel(assigns) do
    panel_class =
      case assigns.chat_mode do
        :expanded -> "dt-chat-panel"
        :collapsed -> "dt-chat-panel is-collapsed"
        :hidden -> "dt-chat-panel is-hidden"
      end

    assigns = assign(assigns, :panel_class, panel_class)

    ~H"""
    <div class={@panel_class}>
      <div class="dt-chat-header">
        <span class="dt-chat-title">Assistant</span>
        <.status_dot :if={@chat_status != :idle} status={@chat_status} />
        <.thread_picker threads={@threads} active_thread_id={@active_thread_id} />
      </div>

      <.tab_bar
        :if={length(@agent_tab_order) > 1}
        agent_tab_order={@agent_tab_order}
        agents={@agents}
        active_agent_id={@active_agent_id}
        inflight={@inflight}
      />

      <.chat_feed
        messages={@messages}
        session_id={@session_id}
        inflight={@inflight}
        active_agent_id={@active_agent_id}
        user_avatar={@user_avatar}
        agent_avatar={@agent_avatar}
        pending={@pending}
        active_step={@active_agent && @active_agent[:step]}
        active_max_steps={@active_agent && @active_agent[:max_steps]}
      />

      <div class="chat-input-area">
        <form id="chat-input-form" phx-submit="send_message" class="chat-input-form">
          <textarea
            name="content"
            id="chat-input"
            placeholder="Ask to generate skills, edit rows, etc..."
            rows="1"
            phx-hook="AutoResize"
          ></textarea>
          <button type="submit" class="btn-send">Send</button>
        </form>
      </div>
    </div>
    """
  end

  # --- New agent dialog ---

  attr(:session_id, :string, default: nil)

  def new_agent_dialog(assigns) do
    roles = Rho.CLI.Config.agent_names()

    # Build parent options from live agents in the session.
    # Disambiguate duplicate role names by appending a short suffix.
    parent_options =
      if assigns.session_id do
        infos =
          Rho.Agent.Registry.list_all(assigns[:session_id])
          |> Enum.sort_by(& &1.agent_id)

        labels = Enum.map(infos, &tab_label_from_info/1)

        # Count occurrences of each label to detect duplicates
        counts = Enum.frequencies(labels)

        {options, _seen} =
          Enum.zip(infos, labels)
          |> Enum.map_reduce(%{}, fn {info, label}, seen ->
            if counts[label] > 1 do
              idx = Map.get(seen, label, 0) + 1
              {{info.agent_id, "#{label} ##{idx}"}, Map.put(seen, label, idx)}
            else
              {{info.agent_id, label}, seen}
            end
          end)

        options
      else
        []
      end

    assigns =
      assigns
      |> assign(:roles, roles)
      |> assign(:parent_options, parent_options)

    ~H"""
    <div class="modal-overlay">
      <div class="modal-dialog" phx-click-away="toggle_new_agent">
        <h3>Create New Agent</h3>

        <form phx-submit="create_agent" phx-hook="ParentPicker" id="new-agent-form">
          <div :if={length(@parent_options) > 0} class="agent-parent-picker">
            <label class="agent-parent-label">Parent agent</label>
            <input type="hidden" name="parent_id" value="" id="new-agent-parent-input" />
            <div class="agent-parent-list">
              <button
                type="button"
                class="agent-parent-btn active"
                data-parent-id=""
                phx-click={Phoenix.LiveView.JS.dispatch("rho:select-parent", detail: %{parent_id: ""})}
              >
                None (top-level)
              </button>
              <button
                :for={{id, label} <- @parent_options}
                type="button"
                class="agent-parent-btn"
                data-parent-id={id}
                phx-click={Phoenix.LiveView.JS.dispatch("rho:select-parent", detail: %{parent_id: id})}
              >
                <%= label %>
              </button>
            </div>
          </div>

          <div class="agent-role-list">
            <label class="agent-role-label">Select role</label>
            <div class="agent-role-buttons">
              <button
                :for={role <- @roles}
                type="submit"
                name="role"
                value={role}
                class="agent-role-btn"
              >
                <%= role %>
              </button>
            </div>
          </div>
        </form>
        <button class="modal-cancel" phx-click="toggle_new_agent">Cancel</button>
      </div>
    </div>
    """
  end

  # --- Debug panel ---

  attr(:projections, :map, required: true)
  attr(:active_agent_id, :string, default: nil)
  attr(:session_id, :string, default: nil)

  def debug_panel(assigns) do
    active_id = assigns.active_agent_id || SessionCore.primary_agent_id(assigns.session_id)
    projection = Map.get(assigns.projections, active_id)

    assigns =
      assigns
      |> assign(:projection, projection)
      |> assign(:debug_agent_id, active_id)

    ~H"""
    <div class="debug-panel">
      <div class="debug-header">
        <h3>Debug: LLM Context</h3>
        <span :if={@projection} class="debug-meta">
          <%= @projection.raw_message_count %> messages, <%= @projection.raw_tool_count %> tools, step <%= @projection.step || "?" %>
        </span>
      </div>
      <div class="debug-body">
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

  # --- Helpers ---

  defp truncate_id(id) when byte_size(id) > 16, do: String.slice(id, 0, 16) <> "..."
  defp truncate_id(id), do: id

  def format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  def format_tokens(n), do: "#{n}"

  defp tab_label(agents, agent_id) do
    case Map.get(agents, agent_id) do
      nil -> "unknown"
      %{role: role} -> to_string(role)
    end
  end

  defp agent_stopped?(agents, agent_id) do
    case Map.get(agents, agent_id) do
      nil -> true
      %{status: :stopped} -> true
      _ -> false
    end
  end

  defp is_primary_tab?(agent_id) do
    case String.split(agent_id, "/") do
      [_sid, "primary"] -> true
      _ -> false
    end
  end

  defp tab_label_from_info(info) do
    name = info[:role] || info[:agent_id]
    segments = String.split(to_string(info.agent_id), "/")

    case segments do
      [_sid, "primary"] -> "primary"
      [_sid, "primary" | rest] -> List.last(rest) || to_string(name)
      _ -> to_string(name)
    end
  end

  defp debug_content_string(content) when is_binary(content), do: content
  defp debug_content_string(other), do: inspect(other, limit: :infinity)
end
