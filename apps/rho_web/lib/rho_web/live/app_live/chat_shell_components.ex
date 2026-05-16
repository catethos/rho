defmodule RhoWeb.AppLive.ChatShellComponents do
  @moduledoc """
  Chat shell components for `RhoWeb.AppLive`.

  This module owns the render-only chat chrome: the side panel, saved-chat
  rail, agent tabs, session controls, upload chips, and workbench suggestion
  chips. AppLive prepares state; this module turns that state into markup.
  """
  use Phoenix.Component

  import RhoWeb.ChatComponents
  import RhoWeb.CoreComponents

  alias RhoWeb.AppLive.ChatRail

  attr(:chat_mode, :atom, default: :expanded)
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
  attr(:total_input_tokens, :integer, required: true)
  attr(:total_output_tokens, :integer, required: true)
  attr(:total_cost, :float, required: true)
  attr(:total_cached_tokens, :integer, required: true)
  attr(:total_reasoning_tokens, :integer, required: true)
  attr(:step_input_tokens, :integer, required: true)
  attr(:step_output_tokens, :integer, required: true)
  attr(:uploads, :any, required: true)
  attr(:debug_mode, :boolean, default: false)
  attr(:active_agent, :map, default: nil)
  attr(:workbench_context, :any, default: nil)
  attr(:connected, :boolean, default: true)
  attr(:conversations, :list, default: [])
  attr(:editing_conversation_id, :string, default: nil)
  attr(:chat_rail_collapsed, :boolean, default: false)
  attr(:files_parsing, :map, default: %{})

  def chat_side_panel(assigns) do
    panel_class =
      case assigns.chat_mode do
        :expanded -> "dt-chat-panel"
        :collapsed -> "dt-chat-panel is-collapsed"
        :hidden -> "dt-chat-panel is-hidden"
      end

    suggestions = workbench_suggestions(assigns.workbench_context)

    assigns =
      assigns
      |> assign(:panel_class, panel_class)
      |> assign(:workbench_suggestions, suggestions)

    ~H"""
    <div class={@panel_class}>
      <div class="dt-chat-header">
        <div class="dt-chat-context">
          <span class="dt-chat-title">Assistant</span>
          <span :if={@active_agent} class="chat-active-agent">
            <%= active_agent_label(@active_agent) %>
          </span>
          <span :if={@debug_mode and @session_id != ""} class="chat-session-id" title={@session_id}>
            <%= truncate_id(@session_id) %>
          </span>
          <.status_dot :if={@chat_status != :idle} status={@chat_status} />
        </div>

        <.session_controls
          session_id={@session_id}
          total_input_tokens={@total_input_tokens}
          total_output_tokens={@total_output_tokens}
          total_cost={@total_cost}
          total_cached_tokens={@total_cached_tokens}
          total_reasoning_tokens={@total_reasoning_tokens}
          step_input_tokens={@step_input_tokens}
          step_output_tokens={@step_output_tokens}
          user_avatar={@user_avatar}
          uploads={@uploads}
          debug_mode={@debug_mode}
        />
      </div>

      <div class="dt-chat-body">
        <.chat_rail_toggle
          collapsed={@chat_rail_collapsed}
          count={length(@conversations)}
        />
        <.chat_rail
          chats={@conversations}
          editing_conversation_id={@editing_conversation_id}
          collapsed={@chat_rail_collapsed}
        />

        <div class="dt-chat-main">
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
            debug_mode={@debug_mode}
          />

          <div class="chat-input-area">
            <div :if={@workbench_suggestions != []} class="workbench-suggestion-strip">
              <button
                :for={suggestion <- @workbench_suggestions}
                type="button"
                class="workbench-suggestion-chip"
                phx-click="send_workbench_suggestion"
                phx-value-content={suggestion.content}
                title={suggestion.content}
              >
                <%= suggestion.label %>
              </button>
            </div>
            <div :if={@uploads.files.entries != [] or @files_parsing != %{}} class="chat-attach-strip">
              <%= for entry <- @uploads.files.entries do %>
                <% entry_errors = upload_errors(@uploads.files, entry) %>
                <div class={["chat-attach-chip", entry_errors != [] && "is-error"]}>
                  <span class="chat-attach-icon"><%= file_icon(entry.client_type, entry.client_name) %></span>
                  <span class="chat-attach-name"><%= entry.client_name %></span>
                  <%= if entry.progress < 100 do %>
                    <span class="chat-attach-progress"><%= entry.progress %>%</span>
                  <% end %>
                  <%= for err <- entry_errors do %>
                    <span class="chat-attach-error"><%= upload_error_msg(err) %></span>
                  <% end %>
                  <button type="button" phx-click="cancel_file" phx-value-ref={entry.ref}
                          class="chat-attach-remove" aria-label="Remove">×</button>
                </div>
              <% end %>
              <%= for {_ref, %{filename: name}} <- @files_parsing do %>
                <div class="chat-attach-chip is-parsing">
                  <span class="chat-attach-icon">⏳</span>
                  <span class="chat-attach-name"><%= name %></span>
                  <span class="chat-attach-progress">parsing…</span>
                  <%!-- v1: no cancel-during-parse. Phoenix can't cleanly pass a Reference back through phx-click. 15s timeout caps the worst case. --%>
                </div>
              <% end %>
            </div>
            <form id="chat-input-form" phx-submit="send_message" phx-change="validate_upload" class="chat-input-form">
              <label class="chat-attach-button" title="Attach .xlsx / .csv / .pdf / .docx / text">
                📎
                <.live_file_input upload={@uploads.files} class="sr-only" />
              </label>
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
      </div>
    </div>
    """
  end

  def new_chat_dialog(assigns) do
    assigns = assign(assigns, :roles, agent_role_options())

    ~H"""
    <div class="modal-overlay">
      <div class="modal-dialog new-chat-dialog" phx-click-away="toggle_new_chat">
        <h3>New Chat</h3>

        <div class="new-chat-role-form">
          <button
            :for={role <- @roles}
            type="button"
            phx-click="new_conversation"
            phx-value-role={role.value}
            class="new-chat-role-btn"
          >
            <span class="new-chat-role-mark"><%= role.mark %></span>
            <span class="new-chat-role-copy">
              <span class="new-chat-role-name"><%= role.label %></span>
              <span :if={role.description != ""} class="new-chat-role-desc">
                <%= role.description %>
              </span>
            </span>
          </button>
        </div>
        <button class="modal-cancel" phx-click="toggle_new_chat">Cancel</button>
      </div>
    </div>
    """
  end

  attr(:session_id, :string, default: nil)
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

  defp session_controls(assigns) do
    ~H"""
    <div class="session-controls">
      <span :if={@debug_mode} class="header-tokens" title="Total input / output tokens (last step input / output)">
        <%= format_tokens(@total_input_tokens) %> in / <%= format_tokens(@total_output_tokens) %> out
        <span :if={@step_input_tokens > 0} class="header-step-tokens">
          (step: <%= format_tokens(@step_input_tokens) %> in / <%= format_tokens(@step_output_tokens) %> out)
        </span>
      </span>
      <span :if={@debug_mode and @total_cached_tokens > 0} class="header-tokens header-cached" title="Cached tokens">
        cached: <%= format_tokens(@total_cached_tokens) %>
      </span>
      <span :if={@debug_mode and @total_reasoning_tokens > 0} class="header-tokens header-reasoning" title="Reasoning tokens">
        reasoning: <%= format_tokens(@total_reasoning_tokens) %>
      </span>
      <span :if={@debug_mode and @total_cost > 0} class="header-cost">
        $<%= :erlang.float_to_binary(@total_cost / 1, decimals: 4) %>
      </span>
      <button class={"header-action-btn #{if @debug_mode, do: "debug-active"}"} phx-click="toggle_debug" title="Toggle debug mode">
        Debug
      </button>
      <button class="header-action-btn header-actions-btn" phx-click="open_workbench_home" title="Show Workbench actions">
        Actions
      </button>
      <button :if={@session_id != ""} class="btn-stop" phx-click="stop_session" title="Stop session">
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
    """
  end

  attr(:agent_tab_order, :list, required: true)
  attr(:agents, :map, required: true)
  attr(:active_agent_id, :string, default: nil)
  attr(:inflight, :map, required: true)

  defp tab_bar(assigns) do
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
          :if={!primary_tab?(agent_id)}
          class="tab-close-btn"
          phx-click="remove_agent"
          phx-value-agent-id={agent_id}
          title="Remove agent"
        >&times;</button>
      </div>
    </div>
    """
  end

  defp primary_tab?(agent_id) do
    case String.split(agent_id, "/") do
      [_sid, "primary"] -> true
      _ -> false
    end
  end

  attr(:chats, :list, default: [])
  attr(:editing_conversation_id, :string, default: nil)
  attr(:collapsed, :boolean, default: false)

  defp chat_rail(assigns) do
    ~H"""
    <div class={["chat-rail", @collapsed && "is-collapsed"]}>
      <div class="chat-rail-head">
        <span class="chat-rail-title">Chats</span>
        <button class="chat-rail-collapse-btn" phx-click="toggle_chat_rail" title="Collapse chats">
          &lsaquo;
        </button>
        <button class="chat-new-btn" phx-click="toggle_new_chat" title="New chat">
          +
        </button>
      </div>
      <div id="chat-list" class="chat-list" phx-hook="ChatReorder">
        <div
          :for={chat <- @chats}
          class={"chat-row #{if chat.active, do: "active", else: ""}"}
          data-chat-id={chat.id}
          data-conversation-id={chat.conversation_id}
        >
          <span
            class="chat-drag-handle"
            draggable="true"
            title="Drag to reorder"
            aria-label="Drag to reorder"
          >
            ⋮⋮
          </span>
          <%= if @editing_conversation_id == chat.conversation_id do %>
            <form class="chat-title-form" phx-submit="rename_chat">
              <input type="hidden" name="conversation_id" value={chat.conversation_id} />
              <input
                type="text"
                name="title"
                value={chat.title}
                class="chat-title-input"
                maxlength="80"
                autofocus
              />
              <button type="submit" class="chat-title-save">Save</button>
              <button
                type="button"
                class="chat-title-cancel"
                phx-click="cancel_chat_title_edit"
                aria-label="Cancel rename"
              >
                ×
              </button>
            </form>
          <% else %>
          <button
            class="chat-open-btn"
            phx-click="open_chat"
            phx-value-conversation_id={chat.conversation_id}
            phx-value-thread_id={chat.thread_id}
            title={chat.title}
          >
            <span class="chat-row-main">
              <span class="chat-row-title"><%= chat.title %></span>
              <span class="chat-row-preview"><%= chat.preview %></span>
            </span>
            <span class="chat-row-meta">
              <span class="chat-row-agent"><%= chat_agent_label(chat) %></span>
              <span><%= chat.updated_label %></span>
            </span>
          </button>
          <button
            class="chat-edit-btn"
            phx-click="edit_chat_title"
            phx-value-conversation_id={chat.conversation_id}
            title="Rename chat"
            aria-label="Rename chat"
          >
            Edit
          </button>
          <button
            class="chat-archive-btn"
            phx-click="archive_chat"
            phx-value-conversation_id={chat.conversation_id}
            phx-value-thread_id={chat.thread_id}
            title="Archive chat"
            aria-label="Archive chat"
            data-confirm="Archive this chat?"
          >
            ×
          </button>
          <% end %>
        </div>
        <div :if={@chats == []} class="chat-empty">
          No saved chats yet
        </div>
      </div>
    </div>
    """
  end

  attr(:collapsed, :boolean, default: false)
  attr(:count, :integer, default: 0)

  defp chat_rail_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class={["chat-rail-tab", @collapsed && "is-collapsed"]}
      phx-click="toggle_chat_rail"
      title={if @collapsed, do: "Show chats", else: "Hide chats"}
    >
      <span>Chats</span>
      <strong><%= @count %></strong>
    </button>
    """
  end

  def workbench_suggestions(%Rho.Stdlib.DataTable.WorkbenchContext{
        active_artifact: %Rho.Stdlib.DataTable.WorkbenchContext.ArtifactSummary{} = artifact
      }) do
    artifact.actions
    |> Enum.map(&workbench_suggestion(&1, artifact))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(3)
  end

  def workbench_suggestions(_), do: []

  defp workbench_suggestion(:generate_levels, artifact) do
    suggestion(
      :generate_levels,
      "Generate proficiency levels for skills missing levels in #{artifact.table_name}."
    )
  end

  defp workbench_suggestion(:save_draft, artifact) do
    suggestion(:save_draft, "Save #{artifact.title} as a draft.")
  end

  defp workbench_suggestion(:create_role_profile, _artifact) do
    nil
  end

  defp workbench_suggestion(:publish, artifact) do
    suggestion(:publish, "Publish #{artifact.title} when it is ready.")
  end

  defp workbench_suggestion(:suggest_skills, artifact) do
    suggestion(:suggest_skills, "Suggest additional skills for #{artifact.title}.")
  end

  defp workbench_suggestion(:seed_framework_from_selected, _artifact) do
    suggestion(
      :seed_framework_from_selected,
      "Create a new skill framework from the selected role candidates."
    )
  end

  defp workbench_suggestion(:clone_selected_role, _artifact) do
    suggestion(:clone_selected_role, "Clone the selected role into a draft role profile.")
  end

  defp workbench_suggestion(:save_role_profile, artifact) do
    library_id = artifact.linked[:library_id]
    role_name = artifact.linked[:role_name] || role_name_from_title(artifact.title)

    content =
      if is_binary(library_id) and library_id != "" do
        "Save #{artifact.title} with manage_role(action: \"save\", name: \"#{role_name}\", resolve_library_id: \"#{library_id}\") so it stays linked to the source skill framework."
      else
        "Save #{artifact.title}."
      end

    suggestion(:save_role_profile, content)
  end

  defp workbench_suggestion(:map_to_framework, artifact) do
    suggestion(:map_to_framework, "Map #{artifact.title} to the linked skill framework.")
  end

  defp workbench_suggestion(:review_gaps, artifact) do
    suggestion(:review_gaps, "Review gaps for #{artifact.title}.")
  end

  defp workbench_suggestion(:resolve_conflicts, _artifact) do
    suggestion(:resolve_conflicts, "Help me resolve the remaining combine conflicts.")
  end

  defp workbench_suggestion(:create_merged_library, _artifact) do
    suggestion(:create_merged_library, "Create the merged library from the resolved preview.")
  end

  defp workbench_suggestion(:resolve_duplicates, _artifact) do
    suggestion(:resolve_duplicates, "Help me resolve the duplicate skill candidates.")
  end

  defp workbench_suggestion(:apply_cleanup, _artifact) do
    suggestion(:apply_cleanup, "Apply the duplicate cleanup decisions to the source framework.")
  end

  defp workbench_suggestion(:save_cleaned_framework, _artifact) do
    suggestion(:save_cleaned_framework, "Save the cleaned framework after deduplication.")
  end

  defp workbench_suggestion(:review_findings, artifact) do
    suggestion(:review_findings, "Review the open findings in #{artifact.title}.")
  end

  defp workbench_suggestion(:apply_recommendations, artifact) do
    suggestion(
      :apply_recommendations,
      "Apply the accepted recommendations from #{artifact.title}."
    )
  end

  defp workbench_suggestion(_action, _artifact), do: nil

  defp suggestion(action, content) do
    %{label: RhoWeb.WorkbenchPresenter.action_label(action), content: content}
  end

  defp role_name_from_title(title) do
    title
    |> to_string()
    |> String.replace_suffix(" Role Requirements", "")
  end

  def format_tokens(n) when n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  def format_tokens(n) when n >= 1000 do
    "#{Float.round(n / 1000, 1)}K"
  end

  def format_tokens(n) do
    "#{n}"
  end

  def agent_role_label(:default), do: "General"
  def agent_role_label("default"), do: "General"
  def agent_role_label(:primary), do: "General"
  def agent_role_label("primary"), do: "General"

  def agent_role_label(role) do
    role
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp agent_role_options do
    Rho.AgentConfig.agent_names()
    |> Enum.map(fn role ->
      description =
        role |> Rho.AgentConfig.agent() |> Map.get(:description) |> ChatRail.truncate(92)

      %{
        value: Atom.to_string(role),
        label: agent_role_label(role),
        mark: role_mark(role),
        description: description || ""
      }
    end)
  end

  defp active_agent_label(%{agent_name: agent_name}) when not is_nil(agent_name) do
    agent_role_label(agent_name)
  end

  defp active_agent_label(%{role: role}) do
    agent_role_label(role)
  end

  defp active_agent_label(_agent), do: "General"

  defp chat_agent_label(chat) do
    chat |> Map.get(:agent_name, :default) |> agent_role_label()
  end

  defp role_mark(:default), do: "G"

  defp role_mark(role) do
    role |> agent_role_label() |> String.first() |> Kernel.||("A")
  end

  defp tab_label(agents, agent_id) do
    case Map.get(agents, agent_id) do
      nil -> "unknown"
      %{agent_name: agent_name} when not is_nil(agent_name) -> agent_role_label(agent_name)
      %{role: role} -> agent_role_label(role)
    end
  end

  defp agent_stopped?(agents, agent_id) do
    case Map.get(agents, agent_id) do
      nil -> true
      %{status: :stopped} -> true
      _ -> false
    end
  end

  defp truncate_id(id) when byte_size(id) > 16 do
    String.slice(id, 0, 16) <> "..."
  end

  defp truncate_id(id), do: id

  defp file_icon(_mime, name) do
    case Path.extname(name) |> String.downcase() do
      ".xlsx" -> "📊"
      ".csv" -> "📄"
      _ -> "📎"
    end
  end

  defp upload_error_msg(:too_large), do: "File too large (max 10MB)"

  defp upload_error_msg(:not_accepted),
    do: "Only .xlsx / .csv / .pdf / .docx / text files supported"

  defp upload_error_msg(:too_many_files), do: "Too many files (max 5)"
  defp upload_error_msg(other), do: "Upload error: #{inspect(other)}"
end
