defmodule RhoWeb.AppLive do
  @moduledoc """
  Unified root LiveView for all org-scoped pages.

  Owns session state (agents, messages, signal subscriptions) across page
  navigations. Uses `live_patch` so switching between Chat, Libraries,
  Roles, Settings, etc. preserves the running session.

  Page-specific rendering is delegated to live_components under
  `RhoWeb.Pages.*`. Chat state is never cleaned on navigation — only
  explicit user action clears it.
  """
  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router
  import RhoWeb.SignalComponents
  alias Rho.Events.Event, as: LiveEvent
  alias RhoWeb.Session.SessionCore
  alias RhoWeb.Session.Shell
  alias RhoWeb.Session.SignalRouter
  alias RhoWeb.Session.Snapshot
  alias RhoWeb.Session.Threads
  alias RhoWeb.Session.Welcome
  alias RhoWeb.AppLive.AgentEvents
  alias RhoWeb.AppLive.ChatEvents
  alias RhoWeb.AppLive.ChatRail
  alias RhoWeb.AppLive.ChatShellComponents
  alias RhoWeb.AppLive.ChatroomEvents
  alias RhoWeb.AppLive.DataTableEvents
  alias RhoWeb.AppLive.LiveEvents
  alias RhoWeb.AppLive.MessageEvents
  alias RhoWeb.AppLive.PageComponents
  alias RhoWeb.AppLive.PageLoader
  alias RhoWeb.AppLive.PageSearchEvents
  alias RhoWeb.AppLive.SmartEntry
  alias RhoWeb.AppLive.WorkbenchEvents
  alias RhoWeb.AppLive.WorkspaceChromeComponents
  alias RhoWeb.AppLive.WorkspaceEvents
  alias RhoWeb.WorkbenchActionComponent
  alias RhoWeb.Workspace.Registry, as: WorkspaceRegistry
  @impl true
  def mount(params, _session, socket) do
    session_id = SessionCore.validate_session_id(params["session_id"])
    live_action = socket.assigns[:live_action]
    active_page = PageLoader.page_for_action(live_action)
    workspaces = determine_workspaces(live_action)

    ws_states =
      Map.new(WorkspaceRegistry.all(), fn mod -> {mod.key(), mod.projection().init()} end)

    agent_avatar = SessionCore.load_agent_avatar()
    initial_keys = Map.keys(workspaces)
    all_keys = Enum.map(WorkspaceRegistry.all(), & &1.key())
    shell = Shell.init(initial_keys, all_keys)

    socket =
      socket
      |> SessionCore.init(active_page: active_page)
      |> assign(:session_id, session_id)
      |> assign(:workspaces, workspaces)
      |> assign(:ws_states, ws_states)
      |> assign(:active_workspace_id, List.first(initial_keys))
      |> assign(:shell, shell)
      |> assign(:agent_avatar, agent_avatar)
      |> assign(:threads, [])
      |> assign(:active_thread_id, nil)
      |> assign(:conversations, [])
      |> assign(:active_conversation_id, nil)
      |> assign(:editing_conversation_id, nil)
      |> assign(:selected_agent_id, nil)
      |> assign(:timeline_open, false)
      |> assign(:drawer_open, false)
      |> assign(:show_new_chat, false)
      |> assign(:uploaded_files, [])
      |> assign(:debug_mode, false)
      |> assign(:debug_projections, %{})
      |> assign(:command_palette_open, false)
      |> assign(:chat_rail_collapsed, true)
      |> assign(:chat_context, %{})
      |> assign(:fork_pending?, false)
      |> assign(:workbench_action_modal, nil)
      |> assign(:workbench_action_form, %{})
      |> assign(:workbench_action_error, nil)
      |> assign(:workbench_action_busy?, false)
      |> assign(:workbench_action_libraries, [])
      |> assign(:workbench_home_libraries, [])
      |> assign(:workbench_home_open?, false)
      |> allow_upload(:images,
        accept: ~w(.jpg .jpeg .png .gif .webp),
        max_entries: 5,
        max_file_size: 10_000_000
      )
      |> allow_upload(:files,
        accept: ~w(.xlsx .csv .pdf .docx .txt .md .markdown .html .htm),
        max_entries: 5,
        max_file_size: 10_000_000
      )
      |> assign(:files_parsing, %{})
      |> assign(:files_pending_send, nil)
      |> then(fn s ->
        if connected?(s) and s.assigns[:session_id] do
          {:ok, _pid} = Rho.Stdlib.Uploads.ensure_started(s.assigns.session_id)
        end

        s
      end)
      |> allow_upload(:avatar,
        accept: ~w(.jpg .jpeg .png .gif .webp),
        max_entries: 1,
        max_file_size: 2_000_000,
        auto_upload: true
      )

    socket =
      if connected?(socket) do
        ensure_opts = session_ensure_opts(live_action)

        socket =
          if session_id do
            socket |> SessionCore.subscribe_and_hydrate(session_id, ensure_opts)
          else
            resume_chat_session(socket, ensure_opts)
          end

        socket
        |> restore_from_snapshot()
        |> Welcome.maybe_render()
        |> refresh_threads()
        |> refresh_conversations()
        |> DataTableEvents.refresh_session()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    live_action = socket.assigns.live_action
    new_page = PageLoader.page_for_action(live_action)
    sid = params["session_id"]
    new_workspaces = determine_workspaces(live_action)
    current_sid = socket.assigns.session_id
    chat_context = extract_chat_context(params)
    socket = socket |> cleanup_previous_page(new_page) |> assign(:active_page, new_page)

    socket =
      cond do
        sid && sid != current_sid && connected?(socket) ->
          case Rho.Agent.Primary.validate_session_id(sid) do
            :ok ->
              socket
              |> SessionCore.unsubscribe()
              |> assign(:session_id, sid)
              |> assign(:chat_context, chat_context)
              |> merge_workspaces(new_workspaces)
              |> SessionCore.subscribe_and_hydrate(sid, session_ensure_opts(live_action))
              |> restore_from_snapshot()
              |> refresh_threads()
              |> refresh_conversations()
              |> DataTableEvents.refresh_session()

            _ ->
              socket
          end

        sid == current_sid || is_nil(sid) ->
          socket
          |> assign(:chat_context, chat_context)
          |> merge_workspaces(new_workspaces)
          |> refresh_conversations()

        true ->
          socket
      end

    socket = socket |> PageLoader.apply_page(new_page, params) |> refresh_conversations()
    {:noreply, socket}
  end

  defp cleanup_previous_page(socket, new_page) do
    prev = socket.assigns[:active_page]

    if prev == new_page do
      socket
    else
      case prev do
        :libraries ->
          cleanup_libraries_page(socket)

        :library_show ->
          socket
          |> assign(:library, nil)
          |> assign(:skill_index, nil)
          |> assign(:grouped_index, nil)
          |> assign(:total_skill_count, 0)
          |> assign(:cluster_skills, %{})
          |> assign(:open_clusters, MapSet.new())
          |> assign(:open_categories, MapSet.new())
          |> assign(:skill_search_results, nil)
          |> assign(:show_diff, false)
          |> assign(:diff_result, nil)
          |> assign(:skill_search_query, "")

        :roles ->
          socket
          |> Phoenix.LiveView.cancel_async(:semantic_search)
          |> assign(:profiles, nil)
          |> assign(:role_grouped, nil)
          |> assign(:role_search_query, "")
          |> assign(:role_search_results, nil)
          |> assign(:role_search_pending?, false)

        :role_show ->
          socket |> assign(:profile, nil) |> assign(:role_skills_grouped, nil)

        :settings ->
          socket |> assign(:org_changeset, nil) |> assign(:user_changeset, nil)

        :members ->
          socket |> assign(:members, nil) |> assign(:invite_error, nil)

        _ ->
          socket
      end
    end
  end

  defp cleanup_libraries_page(socket) do
    socket
    |> assign(:libraries, nil)
    |> assign(:library_search_query, "")
  end

  @impl true
  def render(assigns) do
    case assigns.active_page do
      page when page in [:chat, :chat_show] -> render_chat(assigns)
      :libraries -> render_libraries(assigns)
      :library_show -> render_library_show(assigns)
      :roles -> render_roles(assigns)
      :role_show -> render_role_show(assigns)
      :settings -> render_settings(assigns)
      :members -> render_members(assigns)
      _ -> render_chat(assigns)
    end
  end

  defp render_chat(assigns) do
    active_id = assigns.active_agent_id
    active_messages = Map.get(assigns.agent_messages, active_id, [])

    active_agent =
      if active_id do
        Map.get(assigns.agents, active_id)
      end

    active_inflight =
      if active_id do
        Map.take(assigns.inflight, [active_id])
      else
        primary_id = SessionCore.primary_agent_id(assigns.session_id)
        Map.take(assigns.inflight, [primary_id])
      end

    has_workspaces = map_size(assigns.workspaces) > 0
    chat_mode = chat_panel_mode(assigns)
    overlay_keys = Shell.overlay_keys(assigns.shell)

    overlays =
      Enum.map(overlay_keys, fn key -> {key, WorkspaceRegistry.get(key)} end)
      |> Enum.reject(fn {_key, mod} -> is_nil(mod) end)

    shared_ws_assigns = %{
      session_id: assigns.session_id,
      agents: assigns.agents,
      active_agent_name: agent_name(active_agent),
      workbench_libraries: workbench_libraries(assigns),
      chat_mode: chat_mode,
      workbench_home_open?: assigns.workbench_home_open?,
      streaming: any_agent_busy?(assigns.agents),
      total_cost: assigns.total_cost
    }

    workbench_context = active_workbench_context(assigns, shared_ws_assigns)

    assigns =
      assigns
      |> assign(:active_messages, active_messages)
      |> assign(:active_agent, active_agent)
      |> assign(:active_inflight, active_inflight)
      |> assign(:has_workspaces, has_workspaces)
      |> assign(:chat_mode, chat_mode)
      |> assign(:overlays, overlays)
      |> assign(:available_workspaces, available_workspaces(assigns))
      |> assign(:shared_ws_assigns, shared_ws_assigns)
      |> assign(:workbench_context, workbench_context)

    ~H"""
    <div id="session-root" phx-hook="CommandPalette" class={"session-layout #{if @has_workspaces, do: "workspace-mode", else: ""} #{if @drawer_open, do: "drawer-pinned", else: ""} #{if @debug_mode, do: "debug-mode", else: ""} #{if @shell.focus_workspace_id, do: "focus-mode", else: ""}"}>
      <WorkspaceChromeComponents.workspace_tab_bar
        :if={@has_workspaces}
        workspaces={@workspaces}
        active={@active_workspace_id}
        available={@available_workspaces}
        shell={@shell}
        workbench_home_open?={@workbench_home_open?}
        pending={any_agent_busy?(@agents)}
      />

      <div class="main-panels">
        <%= for {key, _ws} <- @workspaces do %>
          <% ws_mod = WorkspaceRegistry.get(key) %>
          <% ws_assigns = ws_mod.component_assigns(@ws_states[key], @shared_ws_assigns) %>
          <.live_component
            module={ws_mod.component()}
            id={"workspace-#{key}"}
            class={if key == @active_workspace_id, do: "active", else: "hidden"}
            {ws_assigns}
          />
        <% end %>

        <div :if={!@has_workspaces} class="workspace-empty-state">
          <div class="workspace-empty-content">
            <p class="workspace-empty-hint">Workspace panels will appear here</p>
          </div>
        </div>

        <div :if={@has_workspaces} id="panel-resizer" phx-hook="PanelResizer" class="panel-resizer"></div>

        <ChatShellComponents.chat_side_panel
          chat_mode={@chat_mode}
          messages={@active_messages}
          session_id={@session_id || ""}
          inflight={@active_inflight}
          active_agent_id={@active_agent_id || ""}
          user_avatar={@user_avatar}
          agent_avatar={@agent_avatar}
          pending={agent_busy?(@agents, @active_agent_id || SessionCore.primary_agent_id(@session_id))}
          agents={@agents}
          agent_tab_order={@agent_tab_order}
          chat_status={chat_status(assigns)}
          total_input_tokens={@total_input_tokens}
          total_output_tokens={@total_output_tokens}
          total_cost={@total_cost}
          total_cached_tokens={@total_cached_tokens}
          total_reasoning_tokens={@total_reasoning_tokens}
          step_input_tokens={@step_input_tokens}
          step_output_tokens={@step_output_tokens}
          uploads={@uploads}
          debug_mode={@debug_mode}
          active_agent={@active_agent}
          workbench_context={@workbench_context}
          connected={@connected}
          conversations={@conversations}
          editing_conversation_id={@editing_conversation_id}
          chat_rail_collapsed={@chat_rail_collapsed}
          files_parsing={@files_parsing}
        />

        <WorkspaceChromeComponents.debug_panel
          :if={@debug_mode}
          projections={@debug_projections}
          active_agent_id={@active_agent_id}
          session_id={@session_id}
        />
      </div>

      <ChatShellComponents.new_chat_dialog :if={@show_new_chat} />

      <.signal_timeline open={@timeline_open} />

      <.live_component
        module={RhoWeb.AgentDrawerComponent}
        id="agent-drawer"
        open={@drawer_open}
        agent={@agents[@selected_agent_id]}
        session_id={@session_id || ""}
      />

      <WorkspaceChromeComponents.workspace_overlay
        :for={{key, ws_mod} <- @overlays}
        key={key}
        label={ws_mod.label()}
        ws_mod={ws_mod}
        ws_state={@ws_states[key]}
        shared_ws_assigns={@shared_ws_assigns}
      />
      <div
        :if={@overlays != []}
        class="workspace-overlay-backdrop is-visible"
        phx-click="dismiss_overlay"
        phx-value-workspace={@overlays |> List.first() |> elem(0)}
      />

      <.live_component
        module={RhoWeb.CommandPaletteComponent}
        id="command-palette-component"
        open={@command_palette_open}
        workspaces={@workspaces}
        shell={@shell}
      />

      <WorkbenchActionComponent.action_modal
        action={@workbench_action_modal}
        form={@workbench_action_form}
        error={@workbench_action_error}
        busy?={@workbench_action_busy?}
        libraries={@workbench_action_libraries}
        uploads={@uploads}
        org_slug={@current_organization && @current_organization.slug}
      />

      <button
        :if={@shell.focus_workspace_id}
        class="chat-floating-pill"
        phx-click="exit_focus"
      >
        Chat
        <span :if={Shell.total_unseen_chat_count(@shell) > 0} class="pill-unseen-badge">
          <%= Shell.total_unseen_chat_count(@shell) %>
        </span>
      </button>

      <div :if={!@connected} class="reconnect-banner">
        Reconnecting...
      </div>
    </div>
    """
  end

  defp render_libraries(assigns) do
    PageComponents.libraries(assigns)
  end

  defp render_library_show(assigns) do
    PageComponents.library_show(assigns)
  end

  defp render_roles(assigns) do
    PageComponents.roles(assigns)
  end

  defp render_role_show(assigns) do
    PageComponents.role_show(assigns)
  end

  defp render_settings(assigns) do
    PageComponents.settings(assigns)
  end

  defp render_members(assigns) do
    PageComponents.members(assigns)
  end

  @library_events ~w(
    set_default_version delete_library set_default_version_from_show
    filter_status open_fork_modal close_fork_modal update_fork_name
    submit_fork fork_and_edit show_diff hide_diff
  )
  @settings_events ~w(delete_role save_org save_profile delete_org)
  @member_events ~w(invite change_role remove_member transfer_ownership)

  @impl true
  def handle_event("send_message", %{"content" => content}, socket) do
    MessageEvents.handle_event("send_message", %{"content" => content}, socket)
  end

  def handle_event("send_workbench_suggestion", %{"content" => content}, socket) do
    WorkbenchEvents.handle_event("send_workbench_suggestion", %{"content" => content}, socket)
  end

  def handle_event("toggle_chat_rail", _params, socket) do
    {:noreply, assign(socket, :chat_rail_collapsed, !socket.assigns.chat_rail_collapsed)}
  end

  def handle_event("workbench_action_cancel", _params, socket) do
    WorkbenchEvents.handle_event("workbench_action_cancel", %{}, socket)
  end

  def handle_event("workbench_action_change", params, socket) do
    WorkbenchEvents.handle_event("workbench_action_change", params, socket)
  end

  def handle_event("workbench_action_submit", params, socket) do
    WorkbenchEvents.handle_event("workbench_action_submit", params, socket)
  end

  def handle_event("select_tab", %{"agent-id" => agent_id}, socket) do
    AgentEvents.handle_event("select_tab", %{"agent-id" => agent_id}, socket)
  end

  def handle_event("select_agent", %{"agent-id" => agent_id}, socket) do
    AgentEvents.handle_event("select_agent", %{"agent-id" => agent_id}, socket)
  end

  def handle_event("toggle_new_chat", _params, socket) do
    AgentEvents.handle_event("toggle_new_chat", %{}, socket)
  end

  def handle_event("create_agent", %{"role" => role} = params, socket) do
    AgentEvents.handle_event("create_agent", Map.put(params, "role", role), socket)
  end

  def handle_event("remove_agent", %{"agent-id" => agent_id}, socket) do
    AgentEvents.handle_event("remove_agent", %{"agent-id" => agent_id}, socket)
  end

  def handle_event("validate_upload", _params, socket) do
    MessageEvents.handle_event("validate_upload", %{}, socket)
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    MessageEvents.handle_event("cancel_upload", %{"ref" => ref}, socket)
  end

  def handle_event("cancel_file", %{"ref" => ref}, socket) do
    MessageEvents.handle_event("cancel_file", %{"ref" => ref}, socket)
  end

  def handle_event("switch_workspace", %{"workspace" => ws}, socket) do
    WorkspaceEvents.handle_event("switch_workspace", %{"workspace" => ws}, socket)
  end

  def handle_event("collapse_workspace", %{"workspace" => ws}, socket) do
    WorkspaceEvents.handle_event("collapse_workspace", %{"workspace" => ws}, socket)
  end

  def handle_event("pin_workspace", %{"workspace" => ws}, socket) do
    WorkspaceEvents.handle_event("pin_workspace", %{"workspace" => ws}, socket)
  end

  def handle_event("dismiss_overlay", %{"workspace" => ws}, socket) do
    WorkspaceEvents.handle_event("dismiss_overlay", %{"workspace" => ws}, socket)
  end

  def handle_event("add_workspace", %{"workspace" => ws}, socket) do
    WorkspaceEvents.handle_event("add_workspace", %{"workspace" => ws}, socket)
  end

  def handle_event("open_workbench_home", _params, socket) do
    WorkspaceEvents.handle_event("open_workbench_home", %{}, socket)
  end

  def handle_event("close_workspace", %{"workspace" => ws}, socket) do
    WorkspaceEvents.handle_event("close_workspace", %{"workspace" => ws}, socket)
  end

  def handle_event("toggle_chat", _params, socket) do
    WorkspaceEvents.handle_event("toggle_chat", %{}, socket)
  end

  def handle_event("open_chat", %{"conversation_id" => _conversation_id} = params, socket) do
    ChatEvents.handle_event("open_chat", params, socket)
  end

  def handle_event("open_conversation", params, socket) do
    ChatEvents.handle_event("open_conversation", params, socket)
  end

  def handle_event("archive_chat", %{"conversation_id" => _conversation_id} = params, socket) do
    ChatEvents.handle_event("archive_chat", params, socket)
  end

  def handle_event("archive_conversation", %{"conversation_id" => conversation_id}, socket) do
    ChatEvents.handle_event(
      "archive_conversation",
      %{"conversation_id" => conversation_id},
      socket
    )
  end

  def handle_event("new_conversation", params, socket) do
    ChatEvents.handle_event("new_conversation", params, socket)
  end

  def handle_event("edit_chat_title", %{"conversation_id" => conversation_id}, socket) do
    ChatEvents.handle_event("edit_chat_title", %{"conversation_id" => conversation_id}, socket)
  end

  def handle_event("cancel_chat_title_edit", _params, socket) do
    ChatEvents.handle_event("cancel_chat_title_edit", %{}, socket)
  end

  def handle_event(
        "rename_chat",
        %{"conversation_id" => conversation_id, "title" => title},
        socket
      ) do
    ChatEvents.handle_event(
      "rename_chat",
      %{"conversation_id" => conversation_id, "title" => title},
      socket
    )
  end

  def handle_event("reorder_chats", %{"conversation_ids" => ids}, socket) when is_list(ids) do
    ChatEvents.handle_event("reorder_chats", %{"conversation_ids" => ids}, socket)
  end

  def handle_event("switch_thread", %{"thread_id" => thread_id}, socket) do
    ChatEvents.handle_event("switch_thread", %{"thread_id" => thread_id}, socket)
  end

  def handle_event("fork_from_here", %{"entry_id" => entry_id_str}, socket) do
    ChatEvents.handle_event("fork_from_here", %{"entry_id" => entry_id_str}, socket)
  end

  def handle_event("fork_from_here", _params, socket) do
    ChatEvents.handle_event("fork_from_here", %{}, socket)
  end

  def handle_event("new_blank_thread", _params, socket) do
    ChatEvents.handle_event("new_blank_thread", %{}, socket)
  end

  def handle_event("close_thread", %{"thread_id" => thread_id}, socket) do
    ChatEvents.handle_event("close_thread", %{"thread_id" => thread_id}, socket)
  end

  def handle_event("close_drawer", _params, socket) do
    WorkspaceEvents.handle_event("close_drawer", %{}, socket)
  end

  def handle_event("toggle_timeline", _params, socket) do
    WorkspaceEvents.handle_event("toggle_timeline", %{}, socket)
  end

  def handle_event("toggle_debug", _params, socket) do
    WorkspaceEvents.handle_event("toggle_debug", %{}, socket)
  end

  def handle_event("toggle_command_palette", _params, socket) do
    WorkspaceEvents.handle_event("toggle_command_palette", %{}, socket)
  end

  def handle_event("escape_pressed", _params, socket) do
    WorkspaceEvents.handle_event("escape_pressed", %{}, socket)
  end

  def handle_event("enter_focus", _params, socket) do
    WorkspaceEvents.handle_event("enter_focus", %{}, socket)
  end

  def handle_event("exit_focus", _params, socket) do
    WorkspaceEvents.handle_event("exit_focus", %{}, socket)
  end

  def handle_event("stop_session", _params, socket) do
    AgentEvents.handle_event("stop_session", %{}, socket)
  end

  def handle_event("smart_entry_submit", %{"message" => msg}, socket)
      when is_binary(msg) and msg != "" do
    SmartEntry.handle_event("smart_entry_submit", %{"message" => msg}, socket)
  end

  def handle_event("smart_entry_submit", _params, socket) do
    SmartEntry.handle_event("smart_entry_submit", %{}, socket)
  end

  def handle_event("search_libraries", %{"q" => q}, socket) do
    PageSearchEvents.handle_event("search_libraries", %{"q" => q}, socket)
  end

  def handle_event("search_skills", %{"q" => q}, socket) do
    PageSearchEvents.handle_event("search_skills", %{"q" => q}, socket)
  end

  def handle_event("toggle_category", %{"category" => cat}, socket) do
    PageSearchEvents.handle_event("toggle_category", %{"category" => cat}, socket)
  end

  def handle_event("load_cluster", %{"category" => cat, "cluster" => cluster}, socket) do
    PageSearchEvents.handle_event(
      "load_cluster",
      %{"category" => cat, "cluster" => cluster},
      socket
    )
  end

  def handle_event("search_roles", %{"q" => q}, socket) do
    PageSearchEvents.handle_event("search_roles", %{"q" => q}, socket)
  end

  def handle_event(event, params, socket) when event in @library_events do
    RhoWeb.AppLive.LibraryEvents.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @settings_events do
    RhoWeb.AppLive.SettingsEvents.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @member_events do
    RhoWeb.AppLive.MemberEvents.handle_event(event, params, socket)
  end

  @impl true
  def handle_async(:semantic_search, {:ok, %{query: q, results: results}}, socket) do
    PageSearchEvents.handle_async(:semantic_search, {:ok, %{query: q, results: results}}, socket)
  end

  def handle_async(:semantic_search, {:exit, reason}, socket) do
    PageSearchEvents.handle_async(:semantic_search, {:exit, reason}, socket)
  end

  def handle_async(:fork_library, {:ok, {:ok, %{mode: :edit} = meta}}, socket) do
    %{source_name: source_name, org_slug: org_slug, forked_id: forked_id} = meta

    {:noreply,
     socket
     |> assign(:fork_pending?, false)
     |> clear_flash()
     |> put_flash(:info, "Forked \"#{source_name}\" → editing copy")
     |> push_navigate(to: ~p"/orgs/#{org_slug}/flows/edit-framework?library_id=#{forked_id}")}
  end

  def handle_async(:fork_library, {:ok, {:ok, %{mode: :show} = meta}}, socket) do
    %{source_name: source_name, org_slug: org_slug, forked_id: forked_id} = meta

    {:noreply,
     socket
     |> assign(:fork_pending?, false)
     |> clear_flash()
     |> put_flash(:info, "Forked \"#{source_name}\"")
     |> push_patch(to: ~p"/orgs/#{org_slug}/libraries/#{forked_id}")}
  end

  def handle_async(:fork_library, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:fork_pending?, false)
     |> clear_flash()
     |> put_flash(:error, "Fork failed: #{inspect(reason)}")}
  end

  def handle_async(:fork_library, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:fork_pending?, false)
     |> clear_flash()
     |> put_flash(:error, "Fork failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info({:clear_pulse, key}, socket) do
    {:noreply, assign(socket, :shell, Shell.clear_pulse(socket.assigns.shell, key))}
  end

  def handle_info({:smart_entry_result, message, result}, socket) do
    SmartEntry.handle_info({:smart_entry_result, message, result}, socket)
  end

  def handle_info({:command_palette_action, action_id}, socket) do
    WorkspaceEvents.handle_info({:command_palette_action, action_id}, socket)
  end

  def handle_info(:close_command_palette, socket) do
    WorkspaceEvents.handle_info(:close_command_palette, socket)
  end

  def handle_info({:ws_state_update, key, new_state}, socket) do
    {:noreply, SignalRouter.write_ws_state(socket, key, new_state)}
  end

  def handle_info({:workbench_action_open, action_id}, socket) do
    WorkbenchEvents.handle_info({:workbench_action_open, action_id}, socket)
  end

  def handle_info({:workbench_library_open, library_id}, socket) do
    WorkbenchEvents.handle_info({:workbench_library_open, library_id}, socket)
  end

  def handle_info({:workbench_home_open, open?}, socket) do
    {:noreply, assign(socket, :workbench_home_open?, open?)}
  end

  def handle_info({:lens_detail_request, _} = msg, socket) do
    dispatch_to_workspace(socket, RhoWeb.Workspaces.LensDashboard, msg)
  end

  def handle_info({:data_table_refresh, table_name}, socket) do
    DataTableEvents.handle_info({:data_table_refresh, table_name}, socket)
  end

  def handle_info({:navigate_to_library, library_id}, socket) do
    org = socket.assigns.current_organization
    {:noreply, push_patch(socket, to: ~p"/orgs/#{org.slug}/libraries/#{library_id}")}
  end

  def handle_info({:role_candidates_done}, socket) do
    sid = socket.assigns[:session_id]

    if is_binary(sid) do
      content =
        "I've finished selecting role candidates in the role_candidates tab. " <>
          "Combine them into a new framework using `seed_framework_from_roles` " <>
          "with `from_selected_candidates: \"true\"`. Pick a sensible name based on the picks."

      SessionCore.send_message(socket, content)
    else
      {:noreply, socket}
    end
  end

  def handle_info({:data_table_switch_tab, name}, socket) do
    socket
    |> assign(:workbench_home_open?, false)
    |> then(&DataTableEvents.handle_info({:data_table_switch_tab, name}, &1))
  end

  def handle_info({:data_table_close_tab, name}, socket) do
    DataTableEvents.handle_info({:data_table_close_tab, name}, socket)
  end

  def handle_info({:data_table_toggle_row, table, id}, socket) do
    DataTableEvents.handle_info({:data_table_toggle_row, table, id}, socket)
  end

  def handle_info({:data_table_toggle_all, table, visible_ids}, socket) do
    DataTableEvents.handle_info({:data_table_toggle_all, table, visible_ids}, socket)
  end

  def handle_info({:data_table_clear_selection, table}, socket) do
    DataTableEvents.handle_info({:data_table_clear_selection, table}, socket)
  end

  def handle_info({:data_table_view_change, view_key, mode_label}, socket) do
    DataTableEvents.handle_info({:data_table_view_change, view_key, mode_label}, socket)
  end

  def handle_info({:data_table_error, reason}, socket) do
    DataTableEvents.handle_info({:data_table_error, reason}, socket)
  end

  def handle_info(
        {:library_load_complete, table_name, lib_name, lib_version, lib_immutable?},
        socket
      ) do
    DataTableEvents.handle_info(
      {:library_load_complete, table_name, lib_name, lib_version, lib_immutable?},
      socket
    )
  end

  def handle_info({:data_table_save, table_name, new_name}, socket) do
    DataTableEvents.handle_info({:data_table_save, table_name, new_name}, socket)
  end

  def handle_info({:data_table_fork, table_name}, socket) do
    DataTableEvents.handle_info({:data_table_fork, table_name}, socket)
  end

  def handle_info({:data_table_publish, table_name, new_name, version_tag}, socket) do
    DataTableEvents.handle_info({:data_table_publish, table_name, new_name, version_tag}, socket)
  end

  def handle_info({:data_table_flash, message}, socket) do
    DataTableEvents.handle_info({:data_table_flash, message}, socket)
  end

  def handle_info({:suggest_skills, n, table_name, session_id}, socket) do
    DataTableEvents.handle_info({:suggest_skills, n, table_name, session_id}, socket)
  end

  def handle_info({:suggest_completed, added}, socket) when is_list(added) do
    DataTableEvents.handle_info({:suggest_completed, added}, socket)
  end

  def handle_info({:suggest_failed, reason}, socket) do
    DataTableEvents.handle_info({:suggest_failed, reason}, socket)
  end

  def handle_info({:chatroom_mention, target, text}, socket) do
    ChatroomEvents.handle_info({:chatroom_mention, target, text}, socket)
  end

  def handle_info({:chatroom_broadcast, message}, socket) do
    ChatroomEvents.handle_info({:chatroom_broadcast, message}, socket)
  end

  def handle_info({:ui_spec_tick, message_id}, socket) do
    SessionCore.handle_ui_spec_tick(socket, message_id)
  end

  def handle_info(:reconcile_agents, socket) do
    SessionCore.handle_reconciliation(socket)
  end

  def handle_info({ref, {_handle, _parse_result}} = message, socket) when is_reference(ref) do
    MessageEvents.handle_info(message, socket)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when is_reference(ref) do
    MessageEvents.handle_info({:DOWN, ref, :process, nil, reason}, socket)
  end

  def handle_info(%LiveEvent{} = event, socket) do
    LiveEvents.handle_info(event, socket)
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if sid = socket.assigns[:session_id] do
      snapshot = Snapshot.build_snapshot(socket)
      Snapshot.save(sid, user_workspace(socket), snapshot)
    end

    :ok
  end

  defp chat_status(assigns) do
    if any_agent_busy?(assigns.agents) or map_size(assigns.inflight) > 0 do
      :busy
    else
      :idle
    end
  end

  defp agent_busy?(agents, agent_id) do
    case Map.get(agents, agent_id) do
      %{status: :busy} -> true
      _ -> false
    end
  end

  defp any_agent_busy?(agents) do
    Enum.any?(agents, fn {_id, agent} -> agent[:status] == :busy end)
  end

  defp agent_name(nil), do: nil
  defp agent_name(%{agent_name: name}), do: name
  defp agent_name(%{role: role}), do: role
  defp agent_name(_), do: nil

  defp workbench_libraries(assigns) do
    case assigns[:libraries] do
      libraries when is_list(libraries) ->
        libraries

      _ ->
        assigns[:workbench_home_libraries] || []
    end
  end

  def normalize_agent_role(role) when is_binary(role) do
    Enum.find(Rho.AgentConfig.agent_names(), :default, &(Atom.to_string(&1) == role))
  end

  def normalize_agent_role(role) when is_atom(role) do
    if role in Rho.AgentConfig.agent_names() do
      role
    else
      :default
    end
  end

  def normalize_agent_role(_role) do
    :default
  end

  def conversation_agent_name(%{"agent_name" => agent_name}) when is_binary(agent_name) do
    normalize_agent_role(agent_name)
  end

  def conversation_agent_name(_conversation) do
    :default
  end

  @doc false
  def append_message(socket, msg) do
    socket |> RhoWeb.Session.SignalRouter.append_message(msg) |> refresh_conversations()
  end

  defp restore_from_snapshot(socket) do
    sid = socket.assigns[:session_id]

    if sid do
      case Snapshot.load(sid, user_workspace(socket)) do
        {:ok, snapshot} ->
          socket |> Snapshot.apply_snapshot(snapshot) |> tail_replay(sid, snapshot[:snapshot_at])

        _no_snapshot ->
          rebuild_chat_from_active_thread(socket)
      end
    else
      socket
    end
  end

  def rebuild_chat_from_active_thread(socket) do
    sid = socket.assigns[:session_id]

    if sid do
      sid |> Threads.active(user_workspace(socket)) |> then(&rebuild_chat_from_thread(socket, &1))
    else
      socket
    end
  end

  def rebuild_chat_from_thread(socket, nil) do
    socket
  end

  def rebuild_chat_from_thread(socket, %{"tape_name" => tape_name}) when is_binary(tape_name) do
    sid = socket.assigns[:session_id]
    primary_id = Rho.Agent.Primary.agent_id(sid)
    messages = Rho.Trace.Projection.chat(tape_name)
    agent_messages = socket.assigns.agent_messages |> Map.put(primary_id, messages)
    socket |> assign(:agent_messages, agent_messages) |> assign(:active_agent_id, primary_id)
  end

  def switch_to_thread(socket, sid, workspace, thread_id)
      when is_binary(sid) and is_binary(thread_id) do
    current_thread = Threads.active(sid, workspace)

    if current_thread && current_thread["id"] == thread_id do
      socket |> refresh_threads() |> refresh_conversations()
    else
      if current_thread do
        snapshot = Snapshot.build_snapshot(socket)
        Snapshot.save(sid, workspace, snapshot, thread_id: current_thread["id"])
      end

      case Threads.switch(sid, workspace, thread_id) do
        :ok ->
          target =
            Threads.get(sid, workspace, thread_id) ||
              conversation_thread_for_session(sid, thread_id)

          Rho.Agent.Primary.stop(sid)
          socket = SessionCore.unsubscribe(socket)

          start_opts =
            if target && target["tape_name"] do
              [tape_ref: target["tape_name"]]
            else
              []
            end

          socket = SessionCore.subscribe_and_hydrate(socket, sid, start_opts)

          socket
          |> restore_chat_thread_from_snapshot(sid, workspace, thread_id, target)
          |> refresh_threads()
          |> refresh_conversations()

        {:error, _} ->
          socket
      end
    end
  end

  def switch_to_thread(socket, _sid, _workspace, _thread_id) do
    socket
  end

  def maybe_restore_chat_thread(socket, _sid, _workspace, nil) do
    socket
  end

  def maybe_restore_chat_thread(socket, sid, workspace, thread_id) do
    target =
      Threads.get(sid, workspace, thread_id) || conversation_thread_for_session(sid, thread_id)

    restore_chat_thread_from_snapshot(socket, sid, workspace, thread_id, target)
  end

  defp restore_chat_thread_from_snapshot(socket, sid, workspace, thread_id, target) do
    case Snapshot.load(sid, workspace, thread_id: thread_id) do
      {:ok, snap} -> Snapshot.apply_snapshot(socket, snap)
      _ -> rebuild_chat_from_thread(socket, target)
    end
  end

  defp conversation_thread_for_session(sid, thread_id) do
    with %{} = conversation <- Rho.Conversation.get_by_session(sid) do
      Enum.find(conversation["threads"] || [], &(&1["id"] == thread_id))
    end
  end

  def chat_target_thread_id(_conversation, thread_id) when is_binary(thread_id) do
    thread_id
  end

  def chat_target_thread_id(conversation, _thread_id) do
    conversation["active_thread_id"] ||
      conversation |> Map.get("threads", []) |> List.first() |> then(&(&1 && &1["id"]))
  end

  defp maybe_switch_conversation_thread(_conversation_id, nil) do
    :ok
  end

  defp maybe_switch_conversation_thread(conversation_id, thread_id) do
    case Rho.Conversation.switch_thread(conversation_id, thread_id) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  def switch_to_session(socket, sid, opts) do
    socket =
      socket
      |> persist_current_thread_snapshot()
      |> SessionCore.unsubscribe()
      |> assign(:session_id, sid)
      |> reset_session_runtime_assigns()

    ensure_opts = Keyword.merge(session_ensure_opts(socket.assigns.live_action), opts)

    socket
    |> SessionCore.subscribe_and_hydrate(sid, ensure_opts)
    |> restore_from_snapshot()
    |> refresh_threads()
    |> refresh_conversations()
    |> DataTableEvents.refresh_session()
  end

  defp resume_chat_session(socket, ensure_opts) do
    case latest_resumable_conversation(socket) do
      %{"session_id" => sid} = conversation when is_binary(sid) ->
        workspace = conversation["workspace"] || workspace_for_session(socket, sid)
        target_thread_id = chat_target_thread_id(conversation, nil)
        maybe_switch_conversation_thread(conversation["id"], target_thread_id)

        ensure_opts =
          Keyword.merge(ensure_opts,
            workspace: workspace,
            agent_name: conversation_agent_name(conversation)
          )

        socket
        |> assign(:session_id, sid)
        |> SessionCore.subscribe_and_hydrate(sid, ensure_opts)

      _ ->
        socket
    end
  end

  defp latest_resumable_conversation(socket) do
    socket
    |> conversation_list_opts()
    |> Rho.Conversation.list()
    |> Enum.find(&(is_binary(&1["session_id"]) and can_access_conversation?(socket, &1)))
  end

  def clear_active_chat_session(socket) do
    sid = socket.assigns[:session_id]

    socket =
      socket
      |> persist_current_thread_snapshot()
      |> SessionCore.unsubscribe()

    if sid do
      Rho.Agent.Primary.stop(sid)
    end

    socket
    |> assign(:session_id, nil)
    |> assign(:agents, %{})
    |> assign(:active_agent_id, nil)
    |> assign(:agent_tab_order, [])
    |> assign(:agent_messages, %{})
    |> assign(:threads, [])
    |> assign(:active_thread_id, nil)
    |> assign(:active_conversation_id, nil)
    |> assign(:selected_agent_id, nil)
    |> assign(:editing_conversation_id, nil)
    |> assign(:show_new_chat, false)
    |> reset_session_runtime_assigns()
  end

  def persist_current_thread_snapshot(socket) do
    sid = socket.assigns[:session_id]

    if sid do
      workspace = user_workspace(socket)
      snapshot = Snapshot.build_snapshot(socket)
      Snapshot.save(sid, workspace, snapshot)

      if current_thread = Threads.active(sid, workspace) do
        Snapshot.save(sid, workspace, snapshot, thread_id: current_thread["id"])
      end
    end

    socket
  end

  def reset_session_runtime_assigns(socket) do
    socket
    |> assign(:inflight, %{})
    |> assign(:signals, [])
    |> assign(:ui_streams, %{})
    |> assign(:debug_projections, %{})
    |> assign(:total_input_tokens, 0)
    |> assign(:total_output_tokens, 0)
    |> assign(:total_cost, 0.0)
    |> assign(:total_cached_tokens, 0)
    |> assign(:total_reasoning_tokens, 0)
    |> assign(:step_input_tokens, 0)
    |> assign(:step_output_tokens, 0)
    |> assign(:files_parsing, %{})
    |> assign(:files_pending_send, nil)
  end

  def push_chat_session_patch(socket, sid) do
    case get_in(socket.assigns, [:current_organization, Access.key(:slug)]) do
      slug when is_binary(slug) -> push_patch(socket, to: ~p"/orgs/#{slug}/chat/#{sid}")
      _ -> socket
    end
  end

  def maybe_push_new_session_patch(socket, sid, true) do
    if socket.assigns[:active_page] == :chat do
      push_chat_session_patch(socket, sid)
    else
      socket
    end
  end

  def maybe_push_new_session_patch(socket, _sid, false) do
    socket
  end

  defp tail_replay(socket, _sid, nil) do
    socket
  end

  defp tail_replay(socket, sid, since_ms) when is_integer(since_ms) do
    {events, _last_seq} = Rho.Agent.EventLog.read(sid, limit: 10000)

    signals_since =
      events
      |> Enum.filter(fn evt ->
        case evt["emitted_at"] do
          ts when is_integer(ts) -> ts > since_ms
          _ -> false
        end
      end)

    Enum.reduce(signals_since, socket, fn evt, sock ->
      signal = %{
        kind: String.to_existing_atom(evt["type"]),
        data: LiveEvents.deserialize_event_data(evt["data"] || %{}),
        emitted_at: evt["emitted_at"]
      }

      SignalRouter.route(sock, signal, WorkspaceRegistry.all())
    end)
  end

  def init_workspace(socket, key, ws_mod) do
    shell = socket.assigns.shell |> Shell.add_workspace(key) |> Shell.show_chat()

    socket
    |> assign(:workspaces, Map.put(socket.assigns.workspaces, key, ws_mod))
    |> assign(:ws_states, Map.put(socket.assigns.ws_states, key, ws_mod.projection().init()))
    |> assign(:active_workspace_id, key)
    |> assign(:shell, shell)
  end

  def maybe_hydrate_workspace(socket, key, ws_mod) do
    if socket.assigns.session_id do
      hydrate_workspace(socket, socket.assigns.session_id, key, ws_mod)
    else
      socket
    end
  end

  defp determine_workspaces(_live_action) do
    %{data_table: RhoWeb.Workspaces.DataTable}
  end

  defp chat_panel_mode(assigns) do
    cond do
      assigns.active_workspace_id == :chatroom -> :hidden
      map_size(assigns.workspaces) == 0 -> :expanded
      true -> assigns.shell.chat_mode
    end
  end

  defp active_workbench_context(assigns, shared_ws_assigns) do
    case Map.fetch(assigns.workspaces, :data_table) do
      {:ok, _workspace} ->
        assigns.ws_states
        |> Map.get(:data_table)
        |> RhoWeb.Workspaces.DataTable.component_assigns(shared_ws_assigns)
        |> Map.get(:workbench_context)

      :error ->
        nil
    end
  end

  defp dispatch_to_workspace(socket, ws_mod, message) do
    key = ws_mod.key()
    ws_state = SignalRouter.read_ws_state(socket, key)

    context = %{
      session_id: socket.assigns[:session_id],
      organization_id: get_in(socket.assigns, [:current_organization, Access.key(:id)])
    }

    case ws_mod.handle_info(message, ws_state, context) do
      {:noreply, new_ws_state} ->
        {:noreply, SignalRouter.write_ws_state(socket, key, new_ws_state)}

      :skip ->
        {:noreply, socket}
    end
  end

  defp available_workspaces(assigns) do
    open_keys = Map.keys(assigns.workspaces)
    overlay_keys = Shell.overlay_keys(assigns.shell)
    all_visible = open_keys ++ overlay_keys

    WorkspaceRegistry.all()
    |> Enum.reject(fn mod -> mod.key() in all_visible end)
    |> Map.new(fn mod -> {mod.key(), mod} end)
  end

  defp hydrate_workspace(socket, sid, key, ws_mod) do
    {events, _last_seq} = Rho.Agent.EventLog.read(sid, limit: 10000)
    projection = ws_mod.projection()

    state =
      events
      |> Enum.map(fn evt ->
        %{type: evt["type"], data: LiveEvents.deserialize_event_data(evt["data"] || %{})}
      end)
      |> Enum.filter(fn s -> projection.handles?(s.type) end)
      |> Enum.reduce(projection.init(), fn s, st -> projection.reduce(st, s) end)

    SignalRouter.write_ws_state(socket, key, state)
  end

  defp merge_workspaces(socket, new_workspaces) do
    current = socket.assigns.workspaces
    added = Map.drop(new_workspaces, Map.keys(current))

    if map_size(added) == 0 do
      socket
    else
      merged_ws = Map.merge(current, added)

      shell =
        Enum.reduce(added, socket.assigns.shell, fn {_k, key}, sh ->
          Shell.add_workspace(sh, key)
        end)

      socket |> assign(:workspaces, merged_ws) |> assign(:shell, shell)
    end
  end

  def session_ensure_opts(:data_table) do
    [agent_name: :spreadsheet, id_prefix: "sheet"]
  end

  def session_ensure_opts(:chatroom) do
    [id_prefix: "chat"]
  end

  def session_ensure_opts(_) do
    []
  end

  def user_workspace(socket) do
    workspace_for_session(socket, socket.assigns[:session_id])
  end

  def workspace_for_session(socket, sid) do
    case {socket.assigns[:current_user], sid} do
      {%{id: user_id}, sid} when is_binary(sid) -> Rho.Paths.user_workspace(user_id, sid)
      _ -> File.cwd!()
    end
  end

  defp extract_chat_context(params) do
    %{}
    |> maybe_put("library_id", params["library_id"])
    |> maybe_put("context", params["context"])
    |> maybe_put("role_profile_name", params["role_profile_name"])
  end

  defp maybe_put(map, _key, nil) do
    map
  end

  defp maybe_put(map, _key, "") do
    map
  end

  defp maybe_put(map, key, value) when is_binary(value) do
    Map.put(map, key, value)
  end

  def refresh_threads(socket) do
    sid = socket.assigns[:session_id]

    if sid do
      workspace = user_workspace(socket)
      threads = Threads.list(sid, workspace)
      active = Threads.active(sid, workspace)
      socket |> assign(:threads, threads) |> assign(:active_thread_id, active && active["id"])
    else
      socket
    end
  end

  def refresh_conversations(socket) do
    active_conversation = active_conversation(socket)
    active_id = active_conversation && active_conversation["id"]
    active_thread_id = active_conversation && active_conversation["active_thread_id"]
    active_messages = active_conversation_messages(socket)

    conversations =
      socket
      |> conversation_list_opts()
      |> Rho.Conversation.list()
      |> Enum.flat_map(&ChatRail.items(&1, active_id, active_thread_id, active_messages))
      |> Enum.take(24)

    socket |> assign(:conversations, conversations) |> assign(:active_conversation_id, active_id)
  end

  defp active_conversation(socket) do
    case socket.assigns[:session_id] do
      sid when is_binary(sid) -> scoped_conversation_by_session(socket, sid)
      _ -> nil
    end
  end

  defp scoped_conversation_by_session(socket, sid) do
    Rho.Conversation.get_by_session(sid, conversation_list_opts(socket))
  end

  defp conversation_list_opts(socket) do
    [
      user_id: get_in(socket.assigns, [:current_user, Access.key(:id)]),
      organization_id: get_in(socket.assigns, [:current_organization, Access.key(:id)])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp active_conversation_messages(socket) do
    sid = socket.assigns[:session_id]
    agent_id = socket.assigns[:active_agent_id] || (sid && Rho.Agent.Primary.agent_id(sid))

    if agent_id do
      Map.get(socket.assigns[:agent_messages] || %{}, agent_id, [])
    else
      []
    end
  end

  def can_access_conversation?(socket, conversation) do
    user_id = socket.assigns |> get_in([:current_user, Access.key(:id)]) |> stringify_id()
    org_id = socket.assigns |> get_in([:current_organization, Access.key(:id)]) |> stringify_id()

    conversation_matches?(conversation["user_id"], user_id) and
      conversation_matches?(conversation["organization_id"], org_id)
  end

  defp conversation_matches?(nil, _current) do
    true
  end

  defp conversation_matches?(_stored, nil) do
    true
  end

  defp conversation_matches?(stored, current) do
    stringify_id(stored) == stringify_id(current)
  end

  defp stringify_id(nil) do
    nil
  end

  defp stringify_id(value) do
    to_string(value)
  end

  def touch_active_conversation(socket) do
    case active_conversation(socket) do
      %{"id" => conversation_id} -> Rho.Conversation.touch(conversation_id)
      _ -> :ok
    end
  end
end
