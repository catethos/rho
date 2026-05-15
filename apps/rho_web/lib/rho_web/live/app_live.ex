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
  require Logger
  import RhoWeb.CoreComponents
  import RhoWeb.ChatComponents
  import RhoWeb.SignalComponents
  alias Rho.Events.Event, as: LiveEvent
  alias RhoWeb.Session.SessionCore
  alias RhoWeb.Session.Shell
  alias RhoWeb.Session.SignalRouter
  alias RhoWeb.Session.Snapshot
  alias RhoWeb.Session.Threads
  alias RhoWeb.Session.Welcome
  alias RhoWeb.Workspace.Registry, as: WorkspaceRegistry
  @impl true
  def mount(params, _session, socket) do
    session_id = SessionCore.validate_session_id(params["session_id"])
    live_action = socket.assigns[:live_action]
    active_page = page_for_action(live_action)
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
      |> assign(:chat_context, %{})
      |> assign(:fork_pending?, false)
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
        |> refresh_data_table_session()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    live_action = socket.assigns.live_action
    new_page = page_for_action(live_action)
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
              |> refresh_data_table_session()

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

    socket = socket |> apply_page(new_page, params) |> refresh_conversations()
    {:noreply, socket}
  end

  defp apply_page(socket, :libraries, _params) do
    if connected?(socket) do
      org = socket.assigns.current_organization
      libraries = RhoFrameworks.Library.list_libraries(org.id)

      socket
      |> assign(:libraries, libraries)
      |> assign(:library_groups, group_libraries(libraries))
      |> assign(:library_search_query, "")
      |> assign_new(:smart_entry_pending?, fn -> false end)
    else
      socket
      |> assign(:libraries, [])
      |> assign(:library_groups, [])
      |> assign(:library_search_query, "")
      |> assign_new(:smart_entry_pending?, fn -> false end)
    end
  end

  defp apply_page(socket, :library_show, params) do
    id = params["id"]

    if connected?(socket) && id do
      org = socket.assigns.current_organization
      t0 = System.monotonic_time(:microsecond)
      lib = RhoFrameworks.Library.get_visible_library!(org.id, id)
      t_lib = System.monotonic_time(:microsecond)
      index = RhoFrameworks.Library.list_skill_index(id)
      t_index = System.monotonic_time(:microsecond)
      grouped_index = group_skill_index(index)
      t_group = System.monotonic_time(:microsecond)
      research_notes = RhoFrameworks.Library.list_research_notes(id)
      t_notes = System.monotonic_time(:microsecond)
      total_skills = Enum.reduce(index, 0, fn row, acc -> acc + row.count end)

      Logger.info(
        "[library_show timing] lib=#{div(t_lib - t0, 1000)}ms " <>
          "index=#{div(t_index - t_lib, 1000)}ms (#{length(index)} cells, #{total_skills} skills) " <>
          "group=#{div(t_group - t_index, 1000)}ms " <>
          "notes=#{div(t_notes - t_group, 1000)}ms " <> "total=#{div(t_notes - t0, 1000)}ms"
      )

      cluster_skills =
        case params["skill"] do
          nil ->
            %{}

          skill_id ->
            case RhoFrameworks.Library.cluster_for_skill(id, skill_id) do
              nil ->
                %{}

              {raw_cat, raw_cluster} ->
                %{
                  {raw_cat, raw_cluster} =>
                    RhoFrameworks.Library.list_cluster_skills(id, raw_cat, raw_cluster)
                }
            end
        end

      open_clusters = cluster_skills |> Map.keys() |> MapSet.new()

      open_categories =
        for {raw_cat, _raw_cluster} <- Map.keys(cluster_skills), into: MapSet.new(), do: raw_cat

      socket
      |> assign(:library, lib)
      |> assign(:skill_index, index)
      |> assign(:grouped_index, grouped_index)
      |> assign(:total_skill_count, total_skills)
      |> assign(:cluster_skills, cluster_skills)
      |> assign(:open_clusters, open_clusters)
      |> assign(:open_categories, open_categories)
      |> assign(:skill_search_results, nil)
      |> assign(:research_notes, research_notes)
      |> assign(:highlight_skill, params["skill"])
      |> maybe_scroll_to_skill(params["skill"])
      |> assign_new(:status_filter, fn -> nil end)
      |> assign_new(:show_fork_modal, fn -> false end)
      |> assign_new(:fork_name, fn -> "" end)
      |> assign_new(:show_diff, fn -> false end)
      |> assign_new(:diff_result, fn -> nil end)
      |> assign_new(:skill_search_query, fn -> "" end)
      |> refresh_skill_search()
    else
      socket
      |> assign(:library, nil)
      |> assign(:skill_index, [])
      |> assign(:grouped_index, [])
      |> assign(:total_skill_count, 0)
      |> assign(:cluster_skills, %{})
      |> assign(:open_clusters, MapSet.new())
      |> assign(:open_categories, MapSet.new())
      |> assign(:skill_search_results, nil)
      |> assign(:research_notes, [])
      |> assign(:highlight_skill, nil)
      |> assign_new(:status_filter, fn -> nil end)
      |> assign_new(:show_fork_modal, fn -> false end)
      |> assign_new(:fork_name, fn -> "" end)
      |> assign_new(:show_diff, fn -> false end)
      |> assign_new(:diff_result, fn -> nil end)
      |> assign_new(:skill_search_query, fn -> "" end)
    end
  end

  defp apply_page(socket, :roles, _params) do
    if connected?(socket) do
      org = socket.assigns.current_organization
      profiles = RhoFrameworks.Roles.list_role_profiles(org.id, include_public: false)
      grouped = group_roles_by_family(profiles)

      assign(socket,
        profiles: profiles,
        role_grouped: grouped,
        role_search_query: "",
        role_search_results: nil,
        role_search_pending?: false
      )
    else
      assign(socket,
        profiles: [],
        role_grouped: [],
        role_search_query: "",
        role_search_results: nil,
        role_search_pending?: false
      )
    end
  end

  defp apply_page(socket, :role_show, params) do
    id = params["id"]

    if connected?(socket) && id do
      org = socket.assigns.current_organization
      rp = RhoFrameworks.Roles.get_visible_role_profile_with_skills!(org.id, id)
      role_skills_grouped = group_role_skills(rp.role_skills)
      assign(socket, profile: rp, role_skills_grouped: role_skills_grouped)
    else
      assign(socket, profile: nil, role_skills_grouped: %{})
    end
  end

  defp apply_page(socket, :settings, _params) do
    org = socket.assigns.current_organization
    user = socket.assigns.current_user
    membership = socket.assigns.current_membership
    changeset = RhoFrameworks.Accounts.change_organization(org)
    user_changeset = RhoFrameworks.Accounts.change_user_profile(user)

    socket
    |> assign(:org_changeset, to_form(changeset))
    |> assign(:user_changeset, to_form(user_changeset, as: "user"))
    |> assign(:is_owner, RhoFrameworks.Accounts.Authorization.can?(membership, :manage_org))
  end

  defp apply_page(socket, :members, _params) do
    org = socket.assigns.current_organization
    membership = socket.assigns.current_membership
    members = RhoFrameworks.Accounts.list_members(org.id)
    can_manage = RhoFrameworks.Accounts.Authorization.can?(membership, :manage_members)
    is_owner = RhoFrameworks.Accounts.Authorization.can?(membership, :manage_org)

    socket
    |> assign(:members, members)
    |> assign(:can_manage, can_manage)
    |> assign(:is_owner, is_owner)
    |> assign_new(:invite_email, fn -> "" end)
    |> assign_new(:invite_role, fn -> "member" end)
    |> assign_new(:invite_error, fn -> nil end)
  end

  defp apply_page(socket, :chat, params) do
    library_id = params["library_id"]

    if connected?(socket) && library_id do
      load_library_into_data_table(socket, library_id)
    else
      socket
    end
  end

  defp apply_page(socket, _page, _params) do
    socket
  end

  defp maybe_scroll_to_skill(socket, nil) do
    socket
  end

  defp maybe_scroll_to_skill(socket, skill_id) do
    push_event(socket, "scroll_to_skill", %{skill_id: skill_id})
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
      <.workspace_tab_bar
        :if={@has_workspaces}
        workspaces={@workspaces}
        active={@active_workspace_id}
        available={@available_workspaces}
        shell={@shell}
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

        <.chat_side_panel
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
          files_parsing={@files_parsing}
        />

        <.debug_panel
          :if={@debug_mode}
          projections={@debug_projections}
          active_agent_id={@active_agent_id}
          session_id={@session_id}
        />
      </div>

      <.new_chat_dialog :if={@show_new_chat} />

      <.signal_timeline open={@timeline_open} />

      <.live_component
        module={RhoWeb.AgentDrawerComponent}
        id="agent-drawer"
        open={@drawer_open}
        agent={@agents[@selected_agent_id]}
        session_id={@session_id || ""}
      />

      <.workspace_overlay
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
    ~H"""
    <.page_shell>
      <.page_header title="Skill Libraries" subtitle="Browse and manage skill catalogs">
        <:actions>
          <.link
            navigate={~p"/orgs/#{@current_organization.slug}/flows/create-framework"}
            class="btn-secondary"
          >
            Create with Wizard
          </.link>
          <.link patch={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-primary">
            + New Library
          </.link>
        </:actions>
      </.page_header>

      <section class="smart-entry" aria-label="Describe what you want to build">
        <h3 class="smart-entry-title">Or describe it in plain English</h3>
        <p class="smart-entry-hint">
          e.g. <em>"create a framework for backend engineers"</em> — we'll route you to the right wizard with the form pre-filled.
        </p>
        <form phx-submit="smart_entry_submit" class="smart-entry-form">
          <textarea
            name="message"
            class="smart-entry-textarea"
            rows="2"
            placeholder="Describe the framework you want to build…"
            disabled={@smart_entry_pending?}
            required
          ></textarea>
          <button type="submit" class="btn-secondary" disabled={@smart_entry_pending?}>
            <%= if @smart_entry_pending?, do: "Matching…", else: "Suggest →" %>
          </button>
        </form>
      </section>

      <form phx-change="search_libraries" phx-submit="search_libraries" class="search-bar">
        <input
          type="search"
          name="q"
          value={@library_search_query}
          placeholder="Filter libraries by name…"
          phx-debounce="150"
          class="search-input"
          autocomplete="off"
        />
      </form>

      <% filtered_groups = filter_library_groups(@library_groups, @library_search_query) %>

      <.empty_state :if={@library_groups == []}>
        No libraries yet. Create one in the chat editor or load a standard template.
      </.empty_state>

      <.empty_state :if={@library_groups != [] && filtered_groups == []}>
        No libraries match "<%= @library_search_query %>".
      </.empty_state>

      <div :if={filtered_groups != []} class="lib-list">
        <div class="lib-list-header">
          <span class="lib-col-name">Name</span>
          <span class="lib-col-version">Version</span>
          <span class="lib-col-skills">Skills</span>
          <span class="lib-col-updated">Updated</span>
          <span class="lib-col-actions"></span>
        </div>

        <%= for group <- filtered_groups do %>
          <details class="lib-group" open={group.version_count == 1}>
            <summary class="lib-row lib-row-primary">
              <span class="lib-col-name">
                <.link
                  patch={~p"/orgs/#{@current_organization.slug}/libraries/#{group.primary.id}"}
                  class="lib-name-link"
                >
                  <%= group.name %>
                </.link>
                <span :if={group.primary.visibility == "public"} class="badge-public">Public</span>
                <span :if={group.version_count > 1} class="badge-muted">
                  <%= group.version_count %> versions
                </span>
              </span>
              <span class="lib-col-version">
                <span :if={group.primary.version} class="badge-version">
                  v<%= group.primary.version %>
                </span>
                <span :if={group.primary.is_default} class="badge-default">Default</span>
                <span :if={!group.primary.version && !group.primary.immutable} class="badge-draft">
                  Draft
                </span>
                <span :if={group.primary.immutable && !group.primary.version} class="badge-immutable">
                  Standard
                </span>
              </span>
              <span class="lib-col-skills"><%= group.primary.skill_count %></span>
              <span class="lib-col-updated">
                <%= if group.primary.published_at do %>
                  <%= Calendar.strftime(group.primary.published_at, "%b %d, %Y %H:%M") %>
                <% else %>
                  <%= Calendar.strftime(group.primary.updated_at, "%b %d, %Y %H:%M") %>
                <% end %>
              </span>
              <span class="lib-col-actions">
                <button
                  :if={group.primary.version && !group.primary.is_default && group.primary.visibility != "public"}
                  phx-click="set_default_version"
                  phx-value-id={group.primary.id}
                  class="btn-secondary-sm"
                >
                  Set as Default
                </button>
                <.link
                  :if={group.primary.visibility != "public" && !group.primary.immutable}
                  navigate={~p"/orgs/#{@current_organization.slug}/flows/edit-framework?library_id=#{group.primary.id}"}
                  class="btn-secondary-sm"
                >
                  Edit
                </.link>
                <button
                  phx-click="fork_and_edit"
                  phx-value-id={group.primary.id}
                  class="btn-secondary-sm"
                  disabled={@fork_pending?}
                >
                  <%= if @fork_pending?, do: "Forking…", else: "Fork" %>
                </button>
                <button
                  :if={group.primary.visibility != "public"}
                  phx-click="delete_library"
                  phx-value-id={group.primary.id}
                  data-confirm={"Delete '#{group.name}' and all its skills?"}
                  class="btn-danger-sm"
                >
                  Delete
                </button>
              </span>
            </summary>

            <%= for lib <- Enum.drop(group.versions, 1) do %>
              <div class="lib-row lib-row-version">
                <span class="lib-col-name lib-version-indent">
                  <.link
                    patch={~p"/orgs/#{@current_organization.slug}/libraries/#{lib.id}"}
                    class="lib-name-link"
                  >
                    <%= lib.name %>
                  </.link>
                </span>
                <span class="lib-col-version">
                  <span :if={lib.version} class="badge-version">v<%= lib.version %></span>
                  <span :if={lib.is_default} class="badge-default">Default</span>
                  <span :if={!lib.version && !lib.immutable} class="badge-draft">Draft</span>
                  <span :if={lib.immutable && !lib.version} class="badge-immutable">Standard</span>
                </span>
                <span class="lib-col-skills"><%= lib.skill_count %></span>
                <span class="lib-col-updated">
                  <%= if lib.published_at do %>
                    <%= Calendar.strftime(lib.published_at, "%b %d, %Y %H:%M") %>
                  <% else %>
                    <%= Calendar.strftime(lib.updated_at, "%b %d, %Y %H:%M") %>
                  <% end %>
                </span>
                <span class="lib-col-actions">
                  <button
                    :if={lib.version && !lib.is_default && lib.visibility != "public"}
                    phx-click="set_default_version"
                    phx-value-id={lib.id}
                    class="btn-secondary-sm"
                  >
                    Set as Default
                  </button>
                  <.link
                    :if={lib.visibility != "public" && !lib.immutable}
                    navigate={~p"/orgs/#{@current_organization.slug}/flows/edit-framework?library_id=#{lib.id}"}
                    class="btn-secondary-sm"
                  >
                    Edit
                  </.link>
                  <button
                    phx-click="fork_and_edit"
                    phx-value-id={lib.id}
                    class="btn-secondary-sm"
                    disabled={@fork_pending?}
                  >
                    <%= if @fork_pending?, do: "Forking…", else: "Fork" %>
                  </button>
                  <button
                    :if={lib.visibility != "public"}
                    phx-click="delete_library"
                    phx-value-id={lib.id}
                    data-confirm={"Delete this version of '#{lib.name}'?"}
                    class="btn-danger-sm"
                  >
                    Delete
                  </button>
                </span>
              </div>
            <% end %>
          </details>
        <% end %>
      </div>

    </.page_shell>
    """
  end

  defp render_library_show(assigns) do
    search_active? = String.trim(assigns[:skill_search_query] || "") != ""

    assigns =
      assigns
      |> assign(:skill_search_active?, search_active?)
      |> assign(
        :search_grouped,
        if search_active? do
          group_skills(assigns[:skill_search_results] || [])
        else
          []
        end
      )
      |> then(fn a ->
        assign(
          a,
          :filtered_skill_count,
          if search_active? do
            length(a[:skill_search_results] || [])
          else
            0
          end
        )
      end)

    ~H"""
    <.page_shell>
      <div :if={@library} class="breadcrumb">
        <.link patch={~p"/orgs/#{@current_organization.slug}/libraries"}>Libraries</.link>
        <span class="breadcrumb-sep">/</span>
        <span><%= @library.name %></span>
      </div>

      <.page_header :if={@library} title={@library.name} subtitle={@library.description}>
        <:actions>
          <span :if={@library.version} class="badge-version">v<%= @library.version %></span>
          <span :if={@library.is_default} class="badge-default">Default</span>
          <span :if={@library.immutable} class="badge-immutable">Standard (read-only)</span>
          <button
            :if={@library.version && !@library.is_default}
            phx-click="set_default_version_from_show"
            phx-value-id={@library.id}
            class="btn-secondary"
          >
            Set as Default
          </button>
          <button
            :if={@library.immutable}
            phx-click="open_fork_modal"
            class="btn-primary"
            disabled={@fork_pending?}
          >
            <%= if @fork_pending?, do: "Forking…", else: "Fork Library" %>
          </button>
          <button :if={@library.derived_from_id} phx-click={if @show_diff, do: "hide_diff", else: "show_diff"} class="btn-secondary">
            <%= if @show_diff, do: "Hide Diff", else: "Compare to Source" %>
          </button>
          <.link
            patch={~p"/orgs/#{@current_organization.slug}/chat?library_id=#{@library.id}"}
            class="btn-secondary"
          >
            Open in Chat
          </.link>
        </:actions>
      </.page_header>

      <%= if @show_fork_modal do %>
        <div class="modal-backdrop" phx-click="close_fork_modal">
          <div class="modal-content" onclick="event.stopPropagation()">
            <h2 class="modal-title">Fork Library</h2>
            <p class="modal-desc">Create a mutable copy of "<%= @library.name %>" that you can customize.</p>
            <form phx-submit="submit_fork">
              <label class="form-label" for="fork_name">Library name</label>
              <input
                type="text"
                name="fork_name"
                id="fork_name"
                value={@fork_name}
                phx-change="update_fork_name"
                class="form-input"
                autofocus
              />
              <div class="modal-actions">
                <button type="button" phx-click="close_fork_modal" class="btn-secondary">Cancel</button>
                <button type="submit" class="btn-primary">Fork</button>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <%= if @show_diff && @diff_result do %>
        <div class="diff-panel">
          <h3 class="diff-title">Changes from source</h3>
          <div class="diff-stats">
            <span class="diff-stat diff-added"><%= length(@diff_result.added) %> added</span>
            <span class="diff-stat diff-removed"><%= length(@diff_result.removed) %> removed</span>
            <span class="diff-stat diff-modified"><%= length(@diff_result.modified) %> modified</span>
            <span class="diff-stat diff-unchanged"><%= @diff_result.unchanged_count %> unchanged</span>
          </div>
          <div :if={@diff_result.added != []} class="diff-section">
            <h4>Added</h4>
            <ul><li :for={name <- @diff_result.added}><%= name %></li></ul>
          </div>
          <div :if={@diff_result.removed != []} class="diff-section">
            <h4>Removed</h4>
            <ul><li :for={name <- @diff_result.removed}><%= name %></li></ul>
          </div>
          <div :if={@diff_result.modified != []} class="diff-section">
            <h4>Modified</h4>
            <ul><li :for={name <- @diff_result.modified}><%= name %></li></ul>
          </div>
        </div>
      <% end %>

      <details :if={@library && @research_notes != []} class="research-archive">
        <summary class="research-archive-summary">
          <span class="research-archive-arrow"></span>
          <span class="research-archive-title">Research notes</span>
          <span class="badge-muted"><%= length(@research_notes) %></span>
        </summary>
        <ul class="research-archive-list" role="list">
          <li :for={note <- @research_notes} class="research-archive-item">
            <p class="research-fact"><%= note.fact %></p>
            <div class="research-meta">
              <span :if={note.tag} class="research-tag"><%= note.tag %></span>
              <span class="research-source"><%= note.source %></span>
              <span class="research-archive-by">
                <%= if note.inserted_by == "user", do: "added by you", else: "found by agent" %>
              </span>
            </div>
          </li>
        </ul>
      </details>

      <div :if={@library} class="filter-bar">
        <form phx-change="filter_status">
          <select name="status" class="filter-select">
            <option value="" selected={@status_filter == nil}>All statuses</option>
            <option value="draft" selected={@status_filter == "draft"}>Draft</option>
            <option value="published" selected={@status_filter == "published"}>Published</option>
            <option value="archived" selected={@status_filter == "archived"}>Archived</option>
          </select>
        </form>
        <form phx-change="search_skills" phx-submit="search_skills" class="search-bar search-bar--inline">
          <input
            type="search"
            name="q"
            value={@skill_search_query}
            placeholder="Filter skills…"
            phx-debounce="150"
            class="search-input"
            autocomplete="off"
          />
        </form>
        <span class="filter-count">
          <%= if @skill_search_active? do %>
            <%= @filtered_skill_count %> / <%= @total_skill_count %> skills
          <% else %>
            <%= @total_skill_count %> skills
          <% end %>
        </span>
      </div>

      <.empty_state :if={@library && @skill_search_active? && @filtered_skill_count == 0}>
        No skills match "<%= @skill_search_query %>".
      </.empty_state>

      <%= if @skill_search_active? do %>
        <div :for={{category, clusters} <- @search_grouped} class="fw-collapse">
          <details open>
            <summary class="fw-collapse-summary">
              <span class="fw-collapse-arrow"></span>
              <span class="fw-cluster-title"><%= category %></span>
              <span class="badge-muted"><%= Enum.sum(Enum.map(clusters, fn {_, s} -> length(s) end)) %> skills</span>
            </summary>

            <div class="fw-collapse-body">
              <details :for={{cluster, cluster_skills} <- clusters} class="fw-collapse fw-collapse--nested" open>
                <summary class="fw-collapse-summary">
                  <span class="fw-collapse-arrow"></span>
                  <span class="fw-category-title"><%= cluster %></span>
                  <span class="badge-muted"><%= length(cluster_skills) %></span>
                </summary>

                <div class="fw-collapse-body">
                  <.skill_table skills={cluster_skills} highlight_skill={@highlight_skill} />
                </div>
              </details>
            </div>
          </details>
        </div>
      <% else %>
        <% raw_cats = Enum.map(@grouped_index || [], fn {_label, [{_, raw_cat, _, _} | _]} -> raw_cat end) %>
        <%= for {{category, clusters}, raw_cat} <- Enum.zip(@grouped_index || [], raw_cats) do %>
          <div class={"fw-collapse" <> if(MapSet.member?(@open_categories, raw_cat), do: " is-open", else: "")}>
            <button
              type="button"
              class="fw-collapse-summary"
              phx-click="toggle_category"
              phx-value-category={raw_cat || ""}
            >
              <span class="fw-collapse-arrow"></span>
              <span class="fw-cluster-title"><%= category %></span>
              <span class="badge-muted"><%= Enum.sum(Enum.map(clusters, fn {_, _, _, n} -> n end)) %> skills</span>
            </button>

            <div :if={MapSet.member?(@open_categories, raw_cat)} class="fw-collapse-body">
              <div
                :for={{cluster_label, raw_cat, raw_cluster, count} <- clusters}
                class={"fw-collapse fw-collapse--nested" <> if(MapSet.member?(@open_clusters, {raw_cat, raw_cluster}), do: " is-open", else: "")}
              >
                <button
                  type="button"
                  class="fw-collapse-summary"
                  phx-click="load_cluster"
                  phx-value-category={raw_cat || ""}
                  phx-value-cluster={raw_cluster || ""}
                >
                  <span class="fw-collapse-arrow"></span>
                  <span class="fw-category-title"><%= cluster_label %></span>
                  <span class="badge-muted"><%= count %></span>
                </button>

                <div :if={MapSet.member?(@open_clusters, {raw_cat, raw_cluster})} class="fw-collapse-body">
                  <%= case Map.get(@cluster_skills, {raw_cat, raw_cluster}) do %>
                    <% nil -> %>
                      <p class="cluster-loading">Loading…</p>
                    <% skills -> %>
                      <.skill_table skills={skills} highlight_skill={@highlight_skill} />
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      <% end %>

    </.page_shell>
    """
  end

  defp skill_table(assigns) do
    ~H"""
    <table class="rho-table">
      <thead>
        <tr>
          <th>Skill</th>
          <th>Description</th>
          <th>Status</th>
          <th>Levels</th>
        </tr>
      </thead>
      <tbody>
        <%= for skill <- @skills do %>
          <tr
            id={"skill-#{skill.id}"}
            class={"skill-row" <> if(@highlight_skill == skill.id, do: " skill-highlight", else: "")}
            onclick={"this.classList.toggle('skill-expanded');document.getElementById('prof-#{skill.id}').classList.toggle('proficiency-hidden')"}
            style="cursor: pointer;"
          >
            <td><span class="skill-expand-arrow"></span><%= skill.name %></td>
            <td><%= skill.description %></td>
            <td>
              <span class={"badge-#{skill.status}"}><%= skill.status %></span>
            </td>
            <td><%= length(skill.proficiency_levels || []) %></td>
          </tr>
          <tr :if={(skill.proficiency_levels || []) != []} id={"prof-#{skill.id}"} class="proficiency-hidden">
            <td colspan="4" style="padding: 0;">
              <div class="proficiency-panel">
                <div class="proficiency-list">
                  <div :for={level <- Enum.sort_by(skill.proficiency_levels, & &1["level"])} class="proficiency-item">
                    <span class="proficiency-level">L<%= level["level"] %></span>
                    <span class="proficiency-name"><%= level["level_name"] %></span>
                    <span class="proficiency-desc"><%= level["level_description"] %></span>
                  </div>
                </div>
              </div>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end

  defp render_roles(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Role Profiles" subtitle="Manage role profiles and skill requirements">
        <:actions>
          <.link patch={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-primary">
            + New Role Profile
          </.link>
        </:actions>
      </.page_header>

      <form phx-change="search_roles" phx-submit="search_roles" class="search-bar">
        <input
          type="search"
          name="q"
          value={@role_search_query}
          placeholder="Search across your roles + ESCO public catalog…"
          phx-debounce="300"
          class="search-input"
          autocomplete="off"
        />
        <span :if={@role_search_pending?} class="badge-muted">Refining…</span>
      </form>

      <%= if @role_search_results do %>
        <.empty_state :if={@role_search_results == []}>
          No matches for "<%= @role_search_query %>".
        </.empty_state>

        <div :if={@role_search_results != []} class="lib-list">
          <div class="lib-list-header">
            <span class="lib-col-name">Name</span>
            <span class="lib-col-version">Seniority</span>
            <span class="lib-col-skills">Skills</span>
            <span class="lib-col-updated">Family</span>
            <span class="lib-col-actions"></span>
          </div>

          <div :for={rp <- @role_search_results} class="lib-row lib-row-version">
            <span class="lib-col-name">
              <.link
                patch={~p"/orgs/#{@current_organization.slug}/roles/#{rp.id}"}
                class="lib-name-link"
              >
                <%= rp.name %>
              </.link>
              <span :if={rp.organization_id != @current_organization.id} class="badge-public">
                Public
              </span>
            </span>
            <span class="lib-col-version">
              <span :if={rp.seniority_label} class="badge-muted"><%= rp.seniority_label %></span>
            </span>
            <span class="lib-col-skills"><%= rp.skill_count %></span>
            <span class="lib-col-updated"><%= rp.role_family || "—" %></span>
            <span class="lib-col-actions"></span>
          </div>
        </div>
      <% else %>
        <.empty_state :if={@profiles == []}>
          No role profiles yet. Create one in the chat editor.
        </.empty_state>

        <div :if={@profiles != []} class="lib-list">
          <div class="lib-list-header">
            <span class="lib-col-name">Name</span>
            <span class="lib-col-version">Seniority</span>
            <span class="lib-col-skills">Skills</span>
            <span class="lib-col-updated">Updated</span>
            <span class="lib-col-actions"></span>
          </div>

          <%= for {family, family_profiles} <- @role_grouped do %>
            <details class="lib-group" open={length(@role_grouped) <= 3}>
              <summary class="lib-row lib-row-primary">
                <span class="lib-col-name">
                  <span class="lib-name-link"><%= family || "Ungrouped" %></span>
                  <span class="badge-muted"><%= length(family_profiles) %> roles</span>
                </span>
                <span class="lib-col-version"></span>
                <span class="lib-col-skills"></span>
                <span class="lib-col-updated"></span>
                <span class="lib-col-actions"></span>
              </summary>

              <%= for rp <- family_profiles do %>
                <div class="lib-row lib-row-version">
                  <span class="lib-col-name lib-version-indent">
                    <.link
                      patch={~p"/orgs/#{@current_organization.slug}/roles/#{rp.id}"}
                      class="lib-name-link"
                    >
                      <%= rp.name %>
                    </.link>
                    <span :if={rp.organization_id != @current_organization.id} class="badge-public">
                      Public
                    </span>
                  </span>
                  <span class="lib-col-version">
                    <span :if={rp.seniority_label} class="badge-muted"><%= rp.seniority_label %></span>
                  </span>
                  <span class="lib-col-skills"><%= rp.skill_count %></span>
                  <span class="lib-col-updated">
                    <%= Calendar.strftime(rp.updated_at, "%b %d, %Y %H:%M") %>
                  </span>
                  <span class="lib-col-actions">
                    <button
                      :if={rp.organization_id == @current_organization.id}
                      phx-click="delete_role"
                      phx-value-name={rp.name}
                      data-confirm={"Delete role profile '#{rp.name}'?"}
                      class="btn-danger-sm"
                    >
                      Delete
                    </button>
                  </span>
                </div>
              <% end %>
            </details>
          <% end %>
        </div>
      <% end %>
    </.page_shell>
    """
  end

  defp render_role_show(assigns) do
    ~H"""
    <.page_shell>
      <div :if={@profile} class="breadcrumb">
        <.link patch={~p"/orgs/#{@current_organization.slug}/roles"}>Roles</.link>
        <span class="breadcrumb-sep">/</span>
        <span><%= @profile.name %></span>
      </div>

      <.page_header :if={@profile} title={@profile.name} subtitle={role_subtitle(@profile)}>
        <:actions>
          <.link patch={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-secondary">
            Edit in Chat
          </.link>
        </:actions>
      </.page_header>

      <%= if @profile do %>
        <div :if={has_rich_fields?(@profile)} class="fw-section">
          <h2 class="fw-section-title">Role Description</h2>
          <div class="role-description">
            <div :if={@profile.purpose} class="role-field role-field--full">
              <h3 class="role-field-label">Purpose</h3>
              <p><%= @profile.purpose %></p>
            </div>
            <div :if={@profile.accountabilities} class="role-field">
              <h3 class="role-field-label">Accountabilities</h3>
              <p><%= @profile.accountabilities %></p>
            </div>
            <div :if={@profile.success_metrics} class="role-field">
              <h3 class="role-field-label">Success Metrics</h3>
              <p><%= @profile.success_metrics %></p>
            </div>
            <div :if={@profile.qualifications} class="role-field">
              <h3 class="role-field-label">Qualifications</h3>
              <p><%= @profile.qualifications %></p>
            </div>
            <div :if={@profile.reporting_context} class="role-field">
              <h3 class="role-field-label">Reporting Context</h3>
              <p><%= @profile.reporting_context %></p>
            </div>
          </div>
        </div>

        <div class="fw-section">
          <h2 class="fw-section-title">Skill Requirements</h2>

          <details :for={{category, clusters} <- @role_skills_grouped} class="fw-collapse">
            <summary class="fw-collapse-summary">
              <span class="fw-collapse-arrow"></span>
              <span class="fw-cluster-title"><%= category %></span>
              <span class="badge-muted"><%= Enum.sum(Enum.map(clusters, fn {_, s} -> length(s) end)) %> skills</span>
            </summary>

            <div class="fw-collapse-body">
              <details :for={{cluster, skills} <- clusters} class="fw-collapse fw-collapse--nested">
                <summary class="fw-collapse-summary">
                  <span class="fw-collapse-arrow"></span>
                  <span class="fw-category-title"><%= cluster %></span>
                  <span class="badge-muted"><%= length(skills) %></span>
                </summary>

                <div class="fw-collapse-body">
                  <table class="rho-table">
                    <thead>
                      <tr>
                        <th>Skill</th>
                        <th>Level</th>
                        <th>Required</th>
                        <th>Weight</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={rs <- skills}>
                        <td>
                          <.link patch={~p"/orgs/#{@current_organization.slug}/libraries/#{rs.skill.library_id}?skill=#{rs.skill.id}"} class="skill-link">
                            <%= rs.skill.name %>
                          </.link>
                        </td>
                        <td>
                          <span class={"badge-level #{if rs.required, do: "badge-level--required", else: "badge-level--optional"}"}>
                            <%= rs.min_expected_level %>
                          </span>
                        </td>
                        <td>
                          <span class={"required-dot #{unless rs.required, do: "required-dot--no"}"} title={if rs.required, do: "Required", else: "Nice-to-have"} />
                        </td>
                        <td><%= rs.weight %></td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </details>
            </div>
          </details>
        </div>

        <div :if={@profile.work_activities != []} class="fw-section">
          <h2 class="fw-section-title">Work Activities</h2>
          <table class="rho-table">
            <thead>
              <tr>
                <th>Activity</th>
                <th>Frequency</th>
                <th>Time Allocation</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={activity <- @profile.work_activities}>
                <td><%= activity["description"] || activity[:description] %></td>
                <td><%= activity["frequency"] || activity[:frequency] %></td>
                <td><%= activity["time_allocation"] || activity[:time_allocation] %></td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </.page_shell>
    """
  end

  defp render_settings(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Organization Settings" subtitle={"Manage #{@current_organization.name}"}>
        <:actions>
          <.link patch={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-secondary">
            Back
          </.link>
        </:actions>
      </.page_header>

      <div class="form-card">
        <.form for={@org_changeset} phx-submit="save_org">
          <div class="form-group">
            <label for="org_name" class="form-label">Name</label>
            <input
              type="text"
              name="organization[name]"
              id="org_name"
              value={@org_changeset[:name].value}
              class="form-input"
              required
              maxlength="100"
            />
            <p :if={@org_changeset[:name].errors != []} class="form-error">
              <%= elem(hd(@org_changeset[:name].errors), 0) %>
            </p>
          </div>

          <div class="form-group">
            <label class="form-label">Slug (immutable)</label>
            <input
              type="text"
              value={@current_organization.slug}
              class="form-input"
              disabled
            />
          </div>

          <div class="form-group">
            <label class="form-label">Organization ID</label>
            <code class="form-code"><%= @current_organization.id %></code>
          </div>

          <div class="form-group">
            <label for="org_context" class="form-label">Organization Context</label>
            <p class="form-hint">Extra context the AI agent should know about this organization.</p>
            <textarea
              name="organization[context]"
              id="org_context"
              class="form-input"
              rows="4"
              placeholder="e.g. We are a machine learning research team focused on NLP..."
            ><%= @org_changeset[:context].value %></textarea>
          </div>

          <div class="form-actions">
            <button type="submit" class="btn-primary">Save Changes</button>
          </div>
        </.form>
      </div>

      <div class="form-card">
        <h3 class="form-card-title">Your Profile</h3>
        <.form for={@user_changeset} phx-submit="save_profile">
          <div class="form-group">
            <label for="user_display_name" class="form-label">Display Name</label>
            <input
              type="text"
              name="user[display_name]"
              id="user_display_name"
              value={@user_changeset[:display_name].value}
              class="form-input"
            />
          </div>

          <div class="form-group">
            <label for="user_context" class="form-label">User Context</label>
            <p class="form-hint">Extra context the AI agent should know about you.</p>
            <textarea
              name="user[context]"
              id="user_context"
              class="form-input"
              rows="4"
              placeholder="e.g. I'm a senior engineer, prefer concise answers..."
            ><%= @user_changeset[:context].value %></textarea>
          </div>

          <div class="form-actions">
            <button type="submit" class="btn-primary">Save Profile</button>
          </div>
        </.form>
      </div>

      <div :if={@is_owner && !@current_organization.personal} class="form-card danger-zone">
        <h3 class="danger-title">Danger Zone</h3>
        <p class="danger-desc">
          Deleting this organization will permanently remove all its data, including frameworks and memberships.
        </p>
        <button
          phx-click="delete_org"
          data-confirm={"Are you sure you want to delete '#{@current_organization.name}'? This cannot be undone."}
          class="btn-danger"
        >
          Delete Organization
        </button>
      </div>
    </.page_shell>
    """
  end

  defp render_members(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Members" subtitle={"Manage members of #{@current_organization.name}"}>
        <:actions>
          <.link patch={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-secondary">
            Back
          </.link>
        </:actions>
      </.page_header>

      <div :if={@can_manage && !@current_organization.personal} class="form-card">
        <h3 class="form-section-title">Add Member</h3>
        <form phx-submit="invite" class="invite-form">
          <div class="invite-row">
            <input
              type="email"
              name="email"
              value={@invite_email}
              placeholder="user@example.com"
              class="form-input"
              required
            />
            <select name="role" class="form-select">
              <option value="member">Member</option>
              <option value="admin">Admin</option>
              <option value="viewer">Viewer</option>
            </select>
            <button type="submit" class="btn-primary">Add</button>
          </div>
          <p :if={@invite_error} class="form-error"><%= @invite_error %></p>
        </form>
      </div>

      <div :if={@current_organization.personal} class="form-card">
        <p class="muted-text">Personal organizations are single-user only. Create a team organization to collaborate.</p>
      </div>

      <table class="rho-table">
        <thead>
          <tr>
            <th>Email</th>
            <th>Name</th>
            <th>Role</th>
            <th :if={@can_manage}>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={member <- @members}>
            <td><%= member.email %></td>
            <td><%= member.display_name || "\u2014" %></td>
            <td>
              <%= if @can_manage && member.role != "owner" do %>
                <form phx-change="change_role" class="inline-form">
                  <input type="hidden" name="membership_id" value={member.id} />
                  <select name="role" class="form-select-sm">
                    <option value="admin" selected={member.role == "admin"}>Admin</option>
                    <option value="member" selected={member.role == "member"}>Member</option>
                    <option value="viewer" selected={member.role == "viewer"}>Viewer</option>
                  </select>
                </form>
              <% else %>
                <%= member.role %>
              <% end %>
            </td>
            <td :if={@can_manage}>
              <%= if member.role != "owner" do %>
                <button
                  phx-click="remove_member"
                  phx-value-id={member.id}
                  data-confirm={"Remove #{member.email} from this organization?"}
                  class="btn-danger-sm"
                >
                  Remove
                </button>
                <%= if @is_owner do %>
                  <button
                    phx-click="transfer_ownership"
                    phx-value-user-id={member.user_id}
                    data-confirm={"Transfer ownership to #{member.email}? You will be demoted to admin."}
                    class="btn-secondary-sm"
                  >
                    Make Owner
                  </button>
                <% end %>
              <% else %>
                <span class="badge-muted">Owner</span>
              <% end %>
            </td>
          </tr>
        </tbody>
      </table>
    </.page_shell>
    """
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
    content = String.trim(content)

    image_parts =
      consume_uploaded_entries(socket, :images, fn %{path: path}, entry ->
        binary = File.read!(path)
        media_type = entry.client_type || "image/png"
        {:ok, ReqLLM.Message.ContentPart.image(binary, media_type)}
      end)

    has_images = image_parts != []
    has_text = content != ""
    has_pending_files = socket.assigns.uploads.files.entries != []

    if not has_text and not has_images and not has_pending_files do
      {:noreply, socket}
    else
      {sid, socket, created?} =
        if socket.assigns.session_id do
          {socket.assigns.session_id, socket, false}
        else
          ensure_opts = session_ensure_opts(socket.assigns.live_action)
          {new_sid, socket} = SessionCore.ensure_session(socket, nil, ensure_opts)
          socket = SessionCore.subscribe_and_hydrate(socket, new_sid, ensure_opts)
          {new_sid, socket, true}
        end

      socket = maybe_push_new_session_patch(socket, sid, created?)
      {:ok, _pid} = Rho.Stdlib.Uploads.ensure_started(sid)

      file_handles =
        consume_uploaded_entries(socket, :files, fn %{path: tmp_path}, entry ->
          case Rho.Stdlib.Uploads.put(sid, %{
                 filename: entry.client_name,
                 mime: entry.client_type || "application/octet-stream",
                 tmp_path: tmp_path,
                 size: entry.client_size
               }) do
            {:ok, handle} -> {:ok, handle}
            {:error, reason} -> {:postpone, {:error, reason, entry.client_name}}
          end
        end)

      if file_handles == [] do
        submit_to_session(socket, content, image_parts, has_text)
      else
        arm_parse_tasks(socket, content, image_parts, has_text, file_handles)
      end
    end
  end

  def handle_event("send_workbench_suggestion", %{"content" => content}, socket) do
    content = String.trim(content || "")

    if content == "" do
      {:noreply, socket}
    else
      {sid, socket, created?} =
        if socket.assigns.session_id do
          {socket.assigns.session_id, socket, false}
        else
          ensure_opts = session_ensure_opts(socket.assigns.live_action)
          {new_sid, socket} = SessionCore.ensure_session(socket, nil, ensure_opts)
          socket = SessionCore.subscribe_and_hydrate(socket, new_sid, ensure_opts)
          {new_sid, socket, true}
        end

      socket = maybe_push_new_session_patch(socket, sid, created?)

      case SessionCore.send_message(socket, content) do
        {:noreply, socket} ->
          touch_active_conversation(socket)
          {:noreply, refresh_conversations(socket)}
      end
    end
  end

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
    {sid, socket} =
      case socket.assigns.session_id do
        nil ->
          {new_sid, socket} = SessionCore.ensure_session(socket, nil)
          socket = SessionCore.subscribe_and_hydrate(socket, new_sid)
          {new_sid, socket}

        sid ->
          {sid, socket}
      end

    parent_id =
      case params["parent_id"] do
        nil -> Rho.Agent.Primary.agent_id(sid)
        "" -> sid
        id -> id
      end

    agent_id = Rho.Agent.Primary.new_agent_id(parent_id)

    role_atom =
      try do
        String.to_existing_atom(role)
      rescue
        ArgumentError -> :worker
      end

    workspace = user_workspace(socket)
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

    agent_entry = %{
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
      case Rho.Agent.Worker.whereis(agent_id) do
        pid when is_pid(pid) -> GenServer.stop(pid, :normal, 5000)
        nil -> :ok
      end

      Rho.Agent.Registry.unregister(agent_id)
      new_tab_order = Enum.reject(socket.assigns.agent_tab_order, &(&1 == agent_id))
      new_agents = Map.delete(socket.assigns.agents, agent_id)

      active =
        if socket.assigns.active_agent_id == agent_id do
          primary_id
        else
          socket.assigns.active_agent_id
        end

      socket =
        socket
        |> assign(:agent_tab_order, new_tab_order)
        |> assign(:agents, new_agents)
        |> assign(:active_agent_id, active)

      {:noreply, socket}
    end
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, maybe_consume_avatar(socket)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  def handle_event("cancel_file", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  def handle_event("switch_workspace", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    if is_atom(key) and map_key?(socket.assigns.workspaces, key) do
      socket =
        socket
        |> assign(:active_workspace_id, key)
        |> assign(:shell, Shell.clear_activity(socket.assigns.shell, key))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("collapse_workspace", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    if is_atom(key) and map_key?(socket.assigns.shell.workspaces, key) do
      chrome = get_in(socket.assigns.shell, [:workspaces, key])
      shell = Shell.set_collapsed(socket.assigns.shell, key, !chrome.collapsed)
      {:noreply, assign(socket, :shell, shell)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pin_workspace", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    if is_atom(key) do
      ws_mod = WorkspaceRegistry.get(key)
      shell = socket.assigns.shell |> Shell.pin_workspace(key) |> Shell.show_chat()

      workspaces =
        if ws_mod && !map_key?(socket.assigns.workspaces, key) do
          Map.put(socket.assigns.workspaces, key, ws_mod)
        else
          socket.assigns.workspaces
        end

      socket =
        socket
        |> assign(:shell, shell)
        |> assign(:workspaces, workspaces)
        |> assign(:active_workspace_id, key)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_overlay", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    if is_atom(key) do
      shell = Shell.dismiss_overlay(socket.assigns.shell, key)
      {:noreply, assign(socket, :shell, shell)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_workspace", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    cond do
      !is_atom(key) ->
        {:noreply, socket}

      map_key?(socket.assigns.workspaces, key) ->
        {:noreply, assign(socket, :active_workspace_id, key)}

      true ->
        case WorkspaceRegistry.get(key) do
          nil ->
            {:noreply, socket}

          ws_mod ->
            socket = init_workspace(socket, key, ws_mod)
            {:noreply, maybe_hydrate_workspace(socket, key, ws_mod)}
        end
    end
  end

  def handle_event("close_workspace", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    if is_atom(key) and map_key?(socket.assigns.workspaces, key) do
      new_workspaces = Map.delete(socket.assigns.workspaces, key)
      new_ws_states = Map.delete(socket.assigns.ws_states, key)

      active =
        if socket.assigns.active_workspace_id == key do
          new_workspaces |> Map.keys() |> List.first()
        else
          socket.assigns.active_workspace_id
        end

      socket =
        socket
        |> assign(:workspaces, new_workspaces)
        |> assign(:ws_states, new_ws_states)
        |> assign(:active_workspace_id, active)
        |> assign(:shell, Shell.remove_workspace(socket.assigns.shell, key))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_chat", _params, socket) do
    {:noreply, assign(socket, :shell, Shell.toggle_chat(socket.assigns.shell))}
  end

  def handle_event("open_chat", %{"conversation_id" => conversation_id} = params, socket) do
    thread_id = params |> Map.get("thread_id") |> blank_to_nil()

    with %{} = conversation <- Rho.Conversation.get(conversation_id),
         true <- can_access_conversation?(socket, conversation),
         sid when is_binary(sid) <- conversation["session_id"] do
      workspace = conversation["workspace"] || workspace_for_session(socket, sid)
      target_thread_id = chat_target_thread_id(conversation, thread_id)

      socket =
        cond do
          sid == socket.assigns[:session_id] and is_binary(target_thread_id) ->
            switch_to_thread(socket, sid, workspace, target_thread_id)

          sid == socket.assigns[:session_id] ->
            refresh_conversations(socket)

          true ->
            maybe_switch_conversation_thread(conversation["id"], target_thread_id)

            socket
            |> switch_to_session(sid,
              workspace: workspace,
              agent_name: conversation_agent_name(conversation)
            )
            |> maybe_restore_chat_thread(sid, workspace, target_thread_id)
            |> refresh_threads()
            |> refresh_conversations()
            |> push_chat_session_patch(sid)
        end
        |> Welcome.render_for_active_agent()
        |> assign(:editing_conversation_id, nil)
        |> refresh_conversations()

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("open_conversation", params, socket) do
    handle_event("open_chat", params, socket)
  end

  def handle_event("archive_chat", %{"conversation_id" => conversation_id} = params, socket) do
    thread_id = params |> Map.get("thread_id") |> blank_to_nil()
    active_conversation_id = socket.assigns[:active_conversation_id]
    active_thread_id = socket.assigns[:active_thread_id]

    active? =
      chat_row_active?(conversation_id, thread_id, active_conversation_id, active_thread_id)

    with %{} = conversation <- Rho.Conversation.get(conversation_id),
         true <- can_access_conversation?(socket, conversation),
         :ok <- archive_chat_row(socket, conversation, thread_id) do
      {:noreply, after_archive_chat(socket, conversation, active?)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("archive_conversation", %{"conversation_id" => conversation_id}, socket) do
    active? = conversation_id == socket.assigns[:active_conversation_id]

    with %{} = conversation <- Rho.Conversation.get(conversation_id),
         true <- can_access_conversation?(socket, conversation),
         {:ok, _} <- Rho.Conversation.archive(conversation_id) do
      {:noreply, after_archive_chat(socket, conversation, active?)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("new_conversation", params, socket) do
    agent_name = params |> Map.get("role") |> normalize_agent_role()

    socket =
      socket
      |> persist_current_thread_snapshot()
      |> SessionCore.unsubscribe()
      |> reset_session_runtime_assigns()
      |> assign(:chat_context, %{})
      |> assign(:show_new_chat, false)
      |> assign(:editing_conversation_id, nil)

    ensure_opts =
      socket.assigns.live_action |> session_ensure_opts() |> Keyword.put(:agent_name, agent_name)

    {sid, socket} = SessionCore.ensure_session(socket, nil, ensure_opts)
    {:ok, _pid} = Rho.Stdlib.Uploads.ensure_started(sid)

    socket =
      socket
      |> SessionCore.subscribe_and_hydrate(sid, ensure_opts)
      |> rebuild_chat_from_active_thread()
      |> Welcome.maybe_render()
      |> refresh_threads()
      |> refresh_conversations()
      |> refresh_data_table_session()
      |> push_chat_session_patch(sid)

    {:noreply, socket}
  end

  def handle_event("edit_chat_title", %{"conversation_id" => conversation_id}, socket) do
    with %{} = conversation <- Rho.Conversation.get(conversation_id),
         true <- can_access_conversation?(socket, conversation) do
      {:noreply, assign(socket, :editing_conversation_id, conversation_id)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_chat_title_edit", _params, socket) do
    {:noreply, assign(socket, :editing_conversation_id, nil)}
  end

  def handle_event(
        "rename_chat",
        %{"conversation_id" => conversation_id, "title" => title},
        socket
      ) do
    with %{} = conversation <- Rho.Conversation.get(conversation_id),
         true <- can_access_conversation?(socket, conversation),
         {:ok, _conversation} <- Rho.Conversation.set_title(conversation_id, title) do
      {:noreply, socket |> assign(:editing_conversation_id, nil) |> refresh_conversations()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reorder_chats", %{"conversation_ids" => ids}, socket) when is_list(ids) do
    ids =
      ids
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.filter(fn conversation_id ->
        case Rho.Conversation.get(conversation_id) do
          %{} = conversation -> can_access_conversation?(socket, conversation)
          _ -> false
        end
      end)

    if ids != [] do
      Rho.Conversation.reorder(ids)
    end

    {:noreply, refresh_conversations(socket)}
  end

  def handle_event("switch_thread", %{"thread_id" => thread_id}, socket) do
    sid = socket.assigns.session_id
    workspace = user_workspace(socket)
    {:noreply, switch_to_thread(socket, sid, workspace, thread_id)}
  end

  def handle_event("fork_from_here", %{"entry_id" => entry_id_str}, socket) do
    sid = socket.assigns.session_id
    workspace = user_workspace(socket)
    tape_module = Rho.Config.tape_module()
    primary_id = Rho.Agent.Primary.agent_id(sid)

    case Rho.Agent.Registry.get(primary_id) do
      %{tape_ref: tape_name} when is_binary(tape_name) ->
        Threads.init(sid, workspace, tape_name: tape_name)

      _ ->
        :ok
    end

    fork_point =
      case Integer.parse(entry_id_str) do
        {n, _} when n >= 0 -> n
        _ -> nil
      end

    current_thread = Threads.active(sid, workspace)

    if current_thread do
      snapshot = Snapshot.build_snapshot(socket)
      Snapshot.save(sid, workspace, snapshot, thread_id: current_thread["id"])
    end

    case Threads.fork_thread(sid, workspace, tape_module,
           fork_point: fork_point,
           name: "New chat"
         ) do
      {:ok, thread} ->
        Rho.Agent.Primary.stop(sid)
        socket = SessionCore.unsubscribe(socket)
        start_opts = [tape_ref: thread["tape_name"]]
        socket = SessionCore.subscribe_and_hydrate(socket, sid, start_opts)
        socket = rebuild_chat_from_thread(socket, thread)
        fork_snapshot = Snapshot.build_snapshot(socket)
        Snapshot.save(sid, workspace, fork_snapshot, thread_id: thread["id"])
        {:noreply, socket |> refresh_threads() |> refresh_conversations()}

      {:error, reason} ->
        require Logger
        Logger.warning("fork_from_here failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_event("fork_from_here", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("new_blank_thread", _params, socket) do
    sid = socket.assigns.session_id
    workspace = user_workspace(socket)
    tape_module = Rho.Config.tape_module()
    tape_name = "#{sid}_thread_#{:erlang.unique_integer([:positive])}"
    tape_module.bootstrap(tape_name)

    case Threads.create(sid, workspace, %{"name" => "New chat", "tape_name" => tape_name}) do
      {:ok, thread} ->
        current_thread = Threads.active(sid, workspace)

        if current_thread do
          snapshot = Snapshot.build_snapshot(socket)
          Snapshot.save(sid, workspace, snapshot, thread_id: current_thread["id"])
        end

        :ok = Threads.switch(sid, workspace, thread["id"])
        Rho.Agent.Primary.stop(sid)
        socket = SessionCore.unsubscribe(socket)
        start_opts = [tape_ref: tape_name]
        socket = SessionCore.subscribe_and_hydrate(socket, sid, start_opts)

        {:noreply,
         socket
         |> rebuild_chat_from_thread(thread)
         |> refresh_threads()
         |> refresh_conversations()}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_thread", %{"thread_id" => thread_id}, socket) do
    sid = socket.assigns.session_id
    workspace = user_workspace(socket)
    is_active = socket.assigns.active_thread_id == thread_id

    socket =
      if is_active do
        Threads.switch(sid, workspace, "thread_main")
        main = Threads.get(sid, workspace, "thread_main")
        Rho.Agent.Primary.stop(sid)
        socket = SessionCore.unsubscribe(socket)
        start_opts = [tape_ref: main["tape_name"]]
        socket = SessionCore.subscribe_and_hydrate(socket, sid, start_opts)

        case Snapshot.load(sid, workspace, thread_id: "thread_main") do
          {:ok, snap} -> Snapshot.apply_snapshot(socket, snap)
          _ -> rebuild_chat_from_thread(socket, main)
        end
      else
        socket
      end

    Threads.delete(sid, workspace, thread_id)
    {:noreply, socket |> refresh_threads() |> refresh_conversations()}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, :drawer_open, false)}
  end

  def handle_event("toggle_timeline", _params, socket) do
    {:noreply, assign(socket, :timeline_open, !socket.assigns.timeline_open)}
  end

  def handle_event("toggle_debug", _params, socket) do
    {:noreply, assign(socket, :debug_mode, !socket.assigns.debug_mode)}
  end

  def handle_event("toggle_command_palette", _params, socket) do
    {:noreply, assign(socket, :command_palette_open, !socket.assigns.command_palette_open)}
  end

  def handle_event("escape_pressed", _params, socket) do
    shell = socket.assigns.shell

    socket =
      if shell.focus_workspace_id do
        assign(socket, :shell, Shell.exit_focus(shell))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("enter_focus", _params, socket) do
    active = socket.assigns.active_workspace_id

    if active do
      {:noreply, assign(socket, :shell, Shell.enter_focus(socket.assigns.shell, active))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("exit_focus", _params, socket) do
    {:noreply, assign(socket, :shell, Shell.exit_focus(socket.assigns.shell))}
  end

  def handle_event("stop_session", _params, socket) do
    if socket.assigns.session_id do
      Rho.Agent.Primary.stop(socket.assigns.session_id)
    end

    {:noreply, socket}
  end

  def handle_event("smart_entry_submit", %{"message" => msg}, socket)
      when is_binary(msg) and msg != "" do
    parent = self()
    classifier = match_flow_intent_mod()

    Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
      result = classifier.call(%{message: String.trim(msg), known_flows: known_flows_string()})
      send(parent, {:smart_entry_result, msg, result})
    end)

    {:noreply, assign(socket, :smart_entry_pending?, true)}
  end

  def handle_event("smart_entry_submit", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("search_libraries", %{"q" => q}, socket) do
    {:noreply, assign(socket, :library_search_query, q)}
  end

  def handle_event("search_skills", %{"q" => q}, socket) do
    socket = socket |> assign(:skill_search_query, q) |> refresh_skill_search()
    {:noreply, socket}
  end

  def handle_event("toggle_category", %{"category" => cat}, socket) do
    raw_cat =
      if cat == "" do
        nil
      else
        cat
      end

    open = socket.assigns.open_categories

    open =
      if MapSet.member?(open, raw_cat) do
        MapSet.delete(open, raw_cat)
      else
        MapSet.put(open, raw_cat)
      end

    {:noreply, assign(socket, :open_categories, open)}
  end

  def handle_event("load_cluster", %{"category" => cat, "cluster" => cluster}, socket) do
    library_id = socket.assigns.library.id

    raw_cat =
      if cat == "" do
        nil
      else
        cat
      end

    raw_cluster =
      if cluster == "" do
        nil
      else
        cluster
      end

    key = {raw_cat, raw_cluster}
    open = socket.assigns.open_clusters

    if MapSet.member?(open, key) do
      {:noreply, assign(socket, :open_clusters, MapSet.delete(open, key))}
    else
      cache =
        case Map.fetch(socket.assigns.cluster_skills, key) do
          {:ok, _} ->
            socket.assigns.cluster_skills

          :error ->
            opts =
              case socket.assigns[:status_filter] do
                nil -> []
                status -> [status: status]
              end

            skills =
              RhoFrameworks.Library.list_cluster_skills(library_id, raw_cat, raw_cluster, opts)

            Map.put(socket.assigns.cluster_skills, key, skills)
        end

      {:noreply,
       socket |> assign(:cluster_skills, cache) |> assign(:open_clusters, MapSet.put(open, key))}
    end
  end

  def handle_event("search_roles", %{"q" => q}, socket) do
    query = String.trim(q)
    org_id = socket.assigns.current_organization.id

    case query do
      "" ->
        {:noreply,
         socket
         |> Phoenix.LiveView.cancel_async(:semantic_search)
         |> assign(:role_search_query, q)
         |> assign(:role_search_results, nil)
         |> assign(:role_search_pending?, false)}

      _ ->
        fast_results = RhoFrameworks.Roles.find_similar_roles_fast(org_id, query, limit: 50)

        socket =
          socket
          |> Phoenix.LiveView.cancel_async(:semantic_search)
          |> assign(:role_search_query, q)
          |> assign(:role_search_results, fast_results)
          |> assign(:role_search_pending?, true)
          |> Phoenix.LiveView.start_async(:semantic_search, fn ->
            results = RhoFrameworks.Roles.find_similar_roles_semantic(org_id, query, limit: 50)
            %{query: query, results: results}
          end)

        {:noreply, socket}
    end
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

  @inline_total_preview_chars 16000
  defp submit_to_session(socket, content, image_parts, has_text) do
    submit_content = build_submit_content(content, image_parts, has_text)
    display_text = build_display_text(content, image_parts, has_text)

    case SessionCore.send_message(socket, display_text, submit_content: submit_content) do
      {:noreply, socket} ->
        touch_active_conversation(socket)
        {:noreply, refresh_conversations(socket)}
    end
  end

  defp arm_parse_tasks(socket, content, image_parts, has_text, file_handles) do
    sid = socket.assigns.session_id

    {parse_handles, stored_handles} =
      Enum.split_with(file_handles, &Rho.Stdlib.Uploads.Observer.parse_now?(&1.path))

    stored_observations =
      stored_handles
      |> Enum.map(fn handle ->
        {handle.id, {handle, Rho.Stdlib.Uploads.Observer.observe(sid, handle.id)}}
      end)
      |> Map.new()

    parsing =
      parse_handles
      |> Enum.map(fn handle ->
        task =
          Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
            result = Rho.Stdlib.Uploads.Observer.observe(sid, handle.id)
            {handle, result}
          end)

        {task.ref, %{filename: handle.filename, handle_id: handle.id}}
      end)
      |> Map.new()

    pending = %{
      content: content,
      image_parts: image_parts,
      has_text: has_text,
      file_handles: file_handles,
      observations: stored_observations
    }

    socket = socket |> assign(:files_parsing, parsing) |> assign(:files_pending_send, pending)

    if parsing == %{} do
      submit_with_uploads(socket)
    else
      {:noreply, socket}
    end
  end

  defp submit_with_uploads(socket) do
    pending = socket.assigns.files_pending_send

    enriched_text =
      build_enriched_message(pending.content, pending.observations, pending.file_handles)

    enriched_has_text = enriched_text != ""
    socket = assign(socket, :files_pending_send, nil)
    submit_to_session(socket, enriched_text, pending.image_parts, enriched_has_text)
  end

  defp build_enriched_message(content, observations, file_handles) do
    {blocks, _remaining} =
      Enum.map_reduce(file_handles, @inline_total_preview_chars, fn handle, remaining ->
        case Map.get(observations, handle.id) do
          {^handle, {:ok, obs}} ->
            render_upload_block(handle, obs, remaining)

          {_handle, {:ok, obs}} ->
            render_upload_block(handle, obs, remaining)

          {_handle, {:error, reason}} ->
            {"[Upload error: #{handle.filename}: #{format_parse_error(reason)}]", remaining}

          nil ->
            {"[Upload error: #{handle.filename}: missing parse result]", remaining}
        end
      end)

    blocks = Enum.join(blocks, "

")

    if content == "" do
      blocks
    else
      content <> "

" <> blocks
    end
  end

  defp render_upload_block(handle, %{kind: :prose_text, summary_text: text}, remaining) do
    {head, preview} = split_preview_block(text)

    cond do
      preview == nil ->
        {text <> "
[upload_id: #{handle.id}]", remaining}

      remaining <= 0 ->
        {head <> "
[upload_id: #{handle.id}]", remaining}

      true ->
        preview_len = String.length(preview)
        visible = String.slice(preview, 0, remaining)

        suffix =
          if preview_len > remaining do
            "
[Preview truncated.]"
          else
            ""
          end

        block = head <> "

--- Document preview ---
" <> visible <> suffix <> "
--- End preview ---
[upload_id: #{handle.id}]"
        {block, max(remaining - preview_len, 0)}
    end
  end

  defp render_upload_block(handle, %{summary_text: text}, remaining) do
    {text <> "
[upload_id: #{handle.id}]", remaining}
  end

  defp split_preview_block(text) do
    case String.split(text, "

--- Document preview ---
", parts: 2) do
      [head, rest] ->
        case String.split(rest, "
--- End preview ---", parts: 2) do
          [preview, _tail] -> {head, preview}
          _ -> {text, nil}
        end

      _ ->
        {text, nil}
    end
  end

  defp format_parse_error(:parse_timeout) do
    "parsing exceeded 15s"
  end

  defp format_parse_error({:parse_crashed, reason}) do
    "parser crashed (#{inspect(reason)})"
  end

  defp format_parse_error({:io_error, reason}) do
    "I/O error (#{inspect(reason)})"
  end

  defp format_parse_error(other) do
    inspect(other)
  end

  @impl true
  def handle_async(:semantic_search, {:ok, %{query: q, results: results}}, socket) do
    if socket.assigns.role_search_query == q do
      {:noreply,
       socket |> assign(:role_search_results, results) |> assign(:role_search_pending?, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:semantic_search, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :role_search_pending?, false)}
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

  @smart_entry_min_confidence 0.5
  defp dispatch_smart_entry_result(socket, _message, {:ok, %{flow_id: flow_id} = result}) do
    confidence = Map.get(result, :confidence, 0.0)

    case RhoFrameworks.Flows.Registry.get(flow_id) do
      {:ok, _flow_mod} when confidence >= @smart_entry_min_confidence ->
        org = socket.assigns.current_organization
        query = build_intake_query(result, org.id)

        url =
          if query == "" do
            "/orgs/#{org.slug}/flows/#{flow_id}"
          else
            "/orgs/#{org.slug}/flows/#{flow_id}?#{query}"
          end

        socket |> assign(:smart_entry_pending?, false) |> push_navigate(to: url)

      _ ->
        reasoning =
          case Map.get(result, :reasoning) do
            s when is_binary(s) and s != "" -> s
            _ -> "Could not match the message to a known flow."
          end

        socket
        |> assign(:smart_entry_pending?, false)
        |> put_flash(:info, reasoning <> " Try the wizard directly, or rephrase.")
    end
  end

  defp dispatch_smart_entry_result(socket, _message, {:error, reason}) do
    Logger.warning(fn -> "[AppLive] smart_entry classifier failed: #{inspect(reason)}" end)

    socket
    |> assign(:smart_entry_pending?, false)
    |> put_flash(:error, "Couldn't process that — try again or use the wizard directly.")
  end

  defp dispatch_smart_entry_result(socket, _message, _other) do
    socket
    |> assign(:smart_entry_pending?, false)
    |> put_flash(:error, "Unexpected response — try again.")
  end

  @allowed_starting_points ~w(from_template scratch extend_existing merge)
  defp build_intake_query(result, org_id) do
    [:name, :description, :domain, :target_roles]
    |> Enum.reduce([], fn key, acc ->
      case Map.get(result, key) do
        v when is_binary(v) and v != "" -> [{Atom.to_string(key), v} | acc]
        _ -> acc
      end
    end)
    |> maybe_put_starting_point(result)
    |> maybe_put_library_ids(result, org_id)
    |> URI.encode_query()
  end

  defp maybe_put_starting_point(pairs, result) do
    case Map.get(result, :starting_point) do
      sp when sp in @allowed_starting_points -> [{"starting_point", sp} | pairs]
      _ -> pairs
    end
  end

  defp maybe_put_library_ids(pairs, result, org_id) do
    hints = Map.get(result, :library_hints, [])

    libraries =
      if is_binary(org_id) do
        RhoFrameworks.Library.list_libraries(org_id)
      else
        []
      end

    resolved = resolve_library_hints(hints, libraries)

    case resolved do
      [id] -> [{"library_id", id} | pairs]
      [id_a, id_b] -> [{"library_id_a", id_a}, {"library_id_b", id_b} | pairs]
      _ -> pairs
    end
  end

  defp resolve_library_hints(hints, libraries) when is_list(hints) do
    Enum.flat_map(hints, fn hint -> List.wrap(resolve_one_hint(hint, libraries)) end)
  end

  defp resolve_library_hints(_, _) do
    []
  end

  defp resolve_one_hint(hint, libraries) when is_binary(hint) and hint != "" do
    hint_down = String.downcase(hint)
    matches = Enum.filter(libraries, fn %{name: name} -> String.downcase(name) =~ hint_down end)

    case matches do
      [%{id: id}] -> id
      _ -> nil
    end
  end

  defp resolve_one_hint(_, _) do
    nil
  end

  defp match_flow_intent_mod do
    Application.get_env(:rho_web, :match_flow_intent_mod, RhoFrameworks.LLM.MatchFlowIntent)
  end

  defp known_flows_string do
    "- create-framework — Build a brand-new skill framework from scratch (with optional similar-role lookup or domain research). Use when the user wants to design or generate a new framework.
- edit-framework — Edit an existing framework in place: tweak skill names, descriptions, categories, then save back to the same library. Use when the user wants to change/update/fix/edit one of their existing frameworks. Requires a library_hint naming which framework to edit.
"
  end

  defp maybe_consume_avatar(socket) do
    entry = List.first(socket.assigns.uploads.avatar.entries)

    if entry && entry.done? do
      [{binary, media_type}] =
        consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
          {:ok, {File.read!(path), entry.client_type || "image/png"}}
        end)

      SessionCore.save_user_avatar(socket, binary, media_type)
      data_uri = "data:#{media_type};base64,#{Base.encode64(binary)}"
      assign(socket, :user_avatar, data_uri)
    else
      socket
    end
  end

  @impl true
  def handle_info({:clear_pulse, key}, socket) do
    {:noreply, assign(socket, :shell, Shell.clear_pulse(socket.assigns.shell, key))}
  end

  def handle_info({:smart_entry_result, message, result}, socket) do
    {:noreply, dispatch_smart_entry_result(socket, message, result)}
  end

  def handle_info({:command_palette_action, action_id}, socket) do
    socket = assign(socket, :command_palette_open, false)

    socket =
      case action_id do
        "toggle_chat" ->
          assign(socket, :shell, Shell.toggle_chat(socket.assigns.shell))

        "enter_focus" ->
          active = socket.assigns.active_workspace_id

          if active do
            assign(socket, :shell, Shell.enter_focus(socket.assigns.shell, active))
          else
            socket
          end

        "exit_focus" ->
          assign(socket, :shell, Shell.exit_focus(socket.assigns.shell))

        "open_workspace:" <> key_str ->
          key = safe_to_existing_atom(key_str)

          if is_atom(key) do
            assign(socket, :active_workspace_id, key)
          else
            socket
          end

        "switch_thread:" <> thread_id ->
          {:noreply, socket} = handle_event("switch_thread", %{"thread_id" => thread_id}, socket)
          socket

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(:close_command_palette, socket) do
    {:noreply, assign(socket, :command_palette_open, false)}
  end

  def handle_info({:ws_state_update, key, new_state}, socket) do
    {:noreply, SignalRouter.write_ws_state(socket, key, new_state)}
  end

  def handle_info({:lens_detail_request, _} = msg, socket) do
    dispatch_to_workspace(socket, RhoWeb.Workspaces.LensDashboard, msg)
  end

  def handle_info({:data_table_refresh, table_name}, socket) do
    {:noreply, refresh_data_table_active(socket, table_name)}
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
    sid = socket.assigns.session_id
    state = ensure_dt_keys(SignalRouter.read_ws_state(socket, :data_table) || dt_initial_state())

    if name != state.active_table do
      publish_view_focus(sid, name)
    end

    new_state = %{state | active_table: name, view_key: nil, mode_label: nil}

    new_state =
      case sid && Rho.Stdlib.DataTable.get_table_snapshot(sid, name) do
        {:ok, snap} ->
          %{new_state | active_snapshot: snap, active_version: snap.version, error: nil}

        {:error, :not_running} ->
          %{new_state | active_snapshot: nil, active_version: nil, error: :not_running}

        _ ->
          %{new_state | active_snapshot: nil, active_version: nil}
      end

    {:noreply, SignalRouter.write_ws_state(socket, :data_table, new_state)}
  end

  def handle_info({:data_table_toggle_row, table, id}, socket) do
    state = read_dt_state(socket)
    current = Map.get(state.selections, table, MapSet.new())

    new_set =
      if MapSet.member?(current, id) do
        MapSet.delete(current, id)
      else
        MapSet.put(current, id)
      end

    {:noreply, update_selection(socket, state, table, new_set)}
  end

  def handle_info({:data_table_toggle_all, table, visible_ids}, socket) do
    state = read_dt_state(socket)
    current = Map.get(state.selections, table, MapSet.new())
    visible = MapSet.new(visible_ids)
    all_selected? = visible != MapSet.new() and MapSet.subset?(visible, current)

    new_set =
      if all_selected? do
        MapSet.difference(current, visible)
      else
        MapSet.union(current, visible)
      end

    {:noreply, update_selection(socket, state, table, new_set)}
  end

  def handle_info({:data_table_clear_selection, table}, socket) do
    state = read_dt_state(socket)
    {:noreply, update_selection(socket, state, table, MapSet.new())}
  end

  def handle_info({:data_table_view_change, view_key, mode_label}, socket) do
    state = ensure_dt_keys(SignalRouter.read_ws_state(socket, :data_table) || dt_initial_state())
    new_state = %{state | view_key: view_key, mode_label: mode_label}
    {:noreply, SignalRouter.write_ws_state(socket, :data_table, new_state)}
  end

  def handle_info({:data_table_error, reason}, socket) do
    state = ensure_dt_keys(SignalRouter.read_ws_state(socket, :data_table) || dt_initial_state())
    new_state = %{state | error: reason}
    {:noreply, SignalRouter.write_ws_state(socket, :data_table, new_state)}
  end

  def handle_info(
        {:library_load_complete, table_name, lib_name, lib_version, lib_immutable?},
        socket
      ) do
    state = ensure_dt_keys(SignalRouter.read_ws_state(socket, :data_table) || dt_initial_state())

    if state.active_table == table_name do
      version_label = library_version_label(lib_version, lib_immutable?)

      new_state = %{state | mode_label: "Skill Library — #{lib_name}#{version_label}"}
      {:noreply, SignalRouter.write_ws_state(socket, :data_table, new_state)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:data_table_save, table_name, new_name}, socket) do
    {:noreply, RhoWeb.SessionLive.DataTableHelpers.handle_save(socket, table_name, new_name)}
  end

  def handle_info({:data_table_fork, table_name}, socket) do
    {:noreply, RhoWeb.SessionLive.DataTableHelpers.handle_fork(socket, table_name)}
  end

  def handle_info({:data_table_publish, table_name, new_name, version_tag}, socket) do
    {:noreply,
     RhoWeb.SessionLive.DataTableHelpers.handle_publish(socket, table_name, new_name, version_tag)}
  end

  def handle_info({:data_table_flash, message}, socket) do
    {:noreply, RhoWeb.SessionLive.DataTableHelpers.set_flash(socket, message)}
  end

  def handle_info({:suggest_skills, n, table_name, session_id}, socket) do
    org = socket.assigns[:current_organization]
    user = socket.assigns[:current_user]

    if is_nil(org) or is_nil(session_id) do
      send(self(), {:data_table_flash, "Suggest unavailable: no active session."})
      {:noreply, socket}
    else
      scope = %RhoFrameworks.Scope{
        organization_id: org.id,
        session_id: session_id,
        user_id: user && user.id,
        source: :agent,
        reason: "user requested suggest_skills"
      }

      lv_pid = self()

      Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
        case RhoFrameworks.UseCases.SuggestSkills.run(%{n: n, table: table_name}, scope) do
          {:ok, %{added: added}} ->
            send(lv_pid, {:suggest_completed, added})

          {:error, reason} ->
            Logger.warning(fn -> "[Suggest] failed: #{inspect(reason)}" end)
            send(lv_pid, {:suggest_failed, reason})
        end
      end)

      {:noreply, socket}
    end
  end

  def handle_info({:suggest_completed, added}, socket) when is_list(added) do
    flash = format_suggest_flash(added)
    expand_groups = added |> Enum.map(fn s -> {s.category, s.cluster} end) |> Enum.uniq()

    send_update(RhoWeb.DataTableComponent,
      id: "workspace-data_table",
      expand_groups: expand_groups
    )

    {:noreply, RhoWeb.SessionLive.DataTableHelpers.set_flash(socket, flash)}
  end

  def handle_info({:suggest_failed, reason}, socket) do
    {:noreply,
     RhoWeb.SessionLive.DataTableHelpers.set_flash(
       socket,
       "Suggest failed: #{inspect(reason)}"
     )}
  end

  def handle_info({:chatroom_mention, target, text}, socket) do
    with sid when is_binary(sid) <- socket.assigns.session_id,
         {:ok, agent_id} <- resolve_mention_target(sid, target) do
      prev_agent_id = socket.assigns.active_agent_id
      socket = assign(socket, :active_agent_id, agent_id)
      {:noreply, socket} = SessionCore.send_message(socket, text)
      {:noreply, assign(socket, :active_agent_id, prev_agent_id)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:chatroom_broadcast, message}, socket) do
    sid = socket.assigns.session_id

    if sid do
      SessionCore.send_message(socket, message)
    else
      {:noreply, socket}
    end
  end

  def handle_info({:ui_spec_tick, message_id}, socket) do
    SessionCore.handle_ui_spec_tick(socket, message_id)
  end

  def handle_info(:reconcile_agents, socket) do
    SessionCore.handle_reconciliation(socket)
  end

  def handle_info({ref, {handle, parse_result}}, socket) when is_reference(ref) do
    case socket.assigns.files_parsing do
      %{^ref => _} ->
        Process.demonitor(ref, [:flush])
        parsing = Map.delete(socket.assigns.files_parsing, ref)
        pending = socket.assigns.files_pending_send
        observations = Map.put(pending.observations, handle.id, {handle, parse_result})

        socket =
          socket
          |> assign(:files_parsing, parsing)
          |> assign(:files_pending_send, %{pending | observations: observations})

        if parsing == %{} do
          submit_with_uploads(socket)
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when is_reference(ref) do
    case Map.pop(socket.assigns.files_parsing, ref) do
      {nil, _} ->
        {:noreply, socket}

      {%{handle_id: hid, filename: fname}, parsing} ->
        require Logger
        Logger.warning("Upload parse task crashed for #{fname}: #{inspect(reason)}")
        pending = socket.assigns.files_pending_send
        crash_result = {:error, {:parse_crashed, reason}}

        synth_handle = %Rho.Stdlib.Uploads.Handle{
          id: hid,
          filename: fname,
          session_id: socket.assigns.session_id
        }

        observations = Map.put(pending.observations, hid, {synth_handle, crash_result})

        socket =
          socket
          |> assign(:files_parsing, parsing)
          |> assign(:files_pending_send, %{pending | observations: observations})

        if parsing == %{} do
          submit_with_uploads(socket)
        else
          {:noreply, socket}
        end
    end
  end

  def handle_info(%LiveEvent{} = event, socket) do
    sid = socket.assigns.session_id

    if sid do
      cond do
        event.kind == :data_table ->
          {:noreply, apply_data_table_event(socket, event.data)}

        event.kind == :workspace_open ->
          {:noreply, apply_open_workspace_event(socket, event.data)}

        true ->
          data = Map.put_new(event.data, :correlation_id, event.data[:turn_id])
          signal = %{kind: event.kind, data: data, emitted_at: event.timestamp}

          socket =
            try do
              SignalRouter.route(socket, signal, WorkspaceRegistry.all())
            rescue
              e ->
                Logger.error(
                  "[app_live] LiveEvent processing crashed: #{Exception.message(e)} " <>
                    "kind=#{event.kind} agent_id=#{event.agent_id}
" <> Exception.format(:error, e, __STACKTRACE__)
                )

                socket
            end

          socket =
            if refresh_conversation_event?(event.kind) do
              touch_active_conversation(socket)
              refresh_conversations(socket)
            else
              socket
            end

          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
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

  attr(:workspaces, :map, required: true)
  attr(:active, :atom, default: nil)
  attr(:available, :map, default: %{})
  attr(:shell, :map, required: true)
  attr(:pending, :boolean, default: false)

  defp workspace_tab_bar(assigns) do
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

  defp workspace_overlay(assigns) do
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

  attr(:chats, :list, default: [])
  attr(:editing_conversation_id, :string, default: nil)

  defp chat_rail(assigns) do
    ~H"""
    <div class="chat-rail">
      <div class="chat-rail-head">
        <span class="chat-rail-title">Chats</span>
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
  attr(:files_parsing, :map, default: %{})

  defp chat_side_panel(assigns) do
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
        <.chat_rail
          chats={@conversations}
          editing_conversation_id={@editing_conversation_id}
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

  defp new_chat_dialog(assigns) do
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

  attr(:projections, :map, required: true)
  attr(:active_agent_id, :string, default: nil)
  attr(:session_id, :string, default: nil)

  defp debug_panel(assigns) do
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

  defp debug_content_string(content) when is_binary(content) do
    content
  end

  defp debug_content_string(content) do
    inspect(content, limit: :infinity)
  end

  defp debug_command(%{"id" => conversation_id}, _session_id) do
    "mix rho.debug #{conversation_id}"
  end

  defp debug_command(nil, session_id) when is_binary(session_id) do
    "mix rho.debug #{session_id}"
  end

  defp debug_command(_conversation, _session_id) do
    "mix rho.debug <ref>"
  end

  defp page_for_action(:new) do
    :chat
  end

  defp page_for_action(:show) do
    :chat
  end

  defp page_for_action(:chat_new) do
    :chat
  end

  defp page_for_action(:chat_show) do
    :chat
  end

  defp page_for_action(:libraries) do
    :libraries
  end

  defp page_for_action(:library_show) do
    :library_show
  end

  defp page_for_action(:roles) do
    :roles
  end

  defp page_for_action(:role_show) do
    :role_show
  end

  defp page_for_action(:settings) do
    :settings
  end

  defp page_for_action(:members) do
    :members
  end

  defp page_for_action(_) do
    :chat
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

  defp truncate_id(id) when byte_size(id) > 16 do
    String.slice(id, 0, 16) <> "..."
  end

  defp truncate_id(id) do
    id
  end

  defp format_tokens(n) when n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_tokens(n) when n >= 1000 do
    "#{Float.round(n / 1000, 1)}K"
  end

  defp format_tokens(n) do
    "#{n}"
  end

  defp tab_label(agents, agent_id) do
    case Map.get(agents, agent_id) do
      nil -> "unknown"
      %{agent_name: agent_name} when not is_nil(agent_name) -> agent_role_label(agent_name)
      %{role: role} -> agent_role_label(role)
    end
  end

  defp active_agent_label(%{agent_name: agent_name}) when not is_nil(agent_name) do
    agent_role_label(agent_name)
  end

  defp active_agent_label(%{role: role}) do
    agent_role_label(role)
  end

  defp active_agent_label(_agent) do
    "General"
  end

  defp chat_agent_label(chat) do
    chat |> Map.get(:agent_name, :default) |> agent_role_label()
  end

  defp agent_role_options do
    Rho.AgentConfig.agent_names()
    |> Enum.map(fn role ->
      description = role |> Rho.AgentConfig.agent() |> Map.get(:description) |> truncate_text(92)

      %{
        value: Atom.to_string(role),
        label: agent_role_label(role),
        mark: role_mark(role),
        description: description || ""
      }
    end)
  end

  defp normalize_agent_role(role) when is_binary(role) do
    Enum.find(Rho.AgentConfig.agent_names(), :default, &(Atom.to_string(&1) == role))
  end

  defp normalize_agent_role(role) when is_atom(role) do
    if role in Rho.AgentConfig.agent_names() do
      role
    else
      :default
    end
  end

  defp normalize_agent_role(_role) do
    :default
  end

  defp conversation_agent_name(%{"agent_name" => agent_name}) when is_binary(agent_name) do
    normalize_agent_role(agent_name)
  end

  defp conversation_agent_name(_conversation) do
    :default
  end

  defp agent_role_label(:default) do
    "General"
  end

  defp agent_role_label("default") do
    "General"
  end

  defp agent_role_label(:primary) do
    "General"
  end

  defp agent_role_label("primary") do
    "General"
  end

  defp agent_role_label(role) do
    role
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp role_mark(:default) do
    "G"
  end

  defp role_mark(role) do
    role |> agent_role_label() |> String.first() |> Kernel.||("A")
  end

  defp agent_stopped?(agents, agent_id) do
    case Map.get(agents, agent_id) do
      nil -> true
      %{status: :stopped} -> true
      _ -> false
    end
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

  defp rebuild_chat_from_active_thread(socket) do
    sid = socket.assigns[:session_id]

    if sid do
      sid |> Threads.active(user_workspace(socket)) |> then(&rebuild_chat_from_thread(socket, &1))
    else
      socket
    end
  end

  defp rebuild_chat_from_thread(socket, nil) do
    socket
  end

  defp rebuild_chat_from_thread(socket, %{"tape_name" => tape_name}) when is_binary(tape_name) do
    sid = socket.assigns[:session_id]
    primary_id = Rho.Agent.Primary.agent_id(sid)
    messages = Rho.Trace.Projection.chat(tape_name)
    agent_messages = socket.assigns.agent_messages |> Map.put(primary_id, messages)
    socket |> assign(:agent_messages, agent_messages) |> assign(:active_agent_id, primary_id)
  end

  defp switch_to_thread(socket, sid, workspace, thread_id)
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

  defp switch_to_thread(socket, _sid, _workspace, _thread_id) do
    socket
  end

  defp maybe_restore_chat_thread(socket, _sid, _workspace, nil) do
    socket
  end

  defp maybe_restore_chat_thread(socket, sid, workspace, thread_id) do
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

  defp chat_target_thread_id(_conversation, thread_id) when is_binary(thread_id) do
    thread_id
  end

  defp chat_target_thread_id(conversation, _thread_id) do
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

  defp archive_chat_row(socket, conversation, thread_id) when is_binary(thread_id) do
    if length(conversation["threads"] || []) > 1 do
      sid = conversation["session_id"]
      workspace = conversation["workspace"] || workspace_for_session(socket, sid)

      case Threads.delete(sid, workspace, thread_id) do
        :ok -> :ok
        {:error, _reason} -> Rho.Conversation.delete_thread(conversation["id"], thread_id)
      end
    else
      archive_conversation_ok(conversation["id"])
    end
  end

  defp archive_chat_row(_socket, conversation, _thread_id) do
    archive_conversation_ok(conversation["id"])
  end

  defp archive_conversation_ok(conversation_id) do
    case Rho.Conversation.archive(conversation_id) do
      {:ok, _conversation} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp after_archive_chat(socket, conversation, true) do
    if conversation["session_id"] == socket.assigns[:session_id] do
      socket
      |> clear_active_chat_session()
      |> refresh_conversations()
      |> maybe_push_chat_index_patch()
    else
      refresh_conversations(socket)
    end
  end

  defp after_archive_chat(socket, _conversation, _active?) do
    refresh_conversations(socket)
  end

  defp chat_row_active?(conversation_id, thread_id, active_id, active_thread_id)
       when conversation_id == active_id do
    is_nil(thread_id) or is_nil(active_thread_id) or thread_id == active_thread_id
  end

  defp chat_row_active?(_conversation_id, _thread_id, _active_id, _active_thread_id) do
    false
  end

  defp blank_to_nil(nil) do
    nil
  end

  defp blank_to_nil("") do
    nil
  end

  defp blank_to_nil(value) do
    value
  end

  defp switch_to_session(socket, sid, opts) do
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
    |> refresh_data_table_session()
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

  defp clear_active_chat_session(socket) do
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

  defp persist_current_thread_snapshot(socket) do
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

  defp reset_session_runtime_assigns(socket) do
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

  defp push_chat_session_patch(socket, sid) do
    case get_in(socket.assigns, [:current_organization, Access.key(:slug)]) do
      slug when is_binary(slug) -> push_patch(socket, to: ~p"/orgs/#{slug}/chat/#{sid}")
      _ -> socket
    end
  end

  defp maybe_push_chat_index_patch(socket) do
    if socket.assigns[:active_page] == :chat do
      case get_in(socket.assigns, [:current_organization, Access.key(:slug)]) do
        slug when is_binary(slug) -> push_patch(socket, to: ~p"/orgs/#{slug}/chat")
        _ -> socket
      end
    else
      socket
    end
  end

  defp maybe_push_new_session_patch(socket, sid, true) do
    if socket.assigns[:active_page] == :chat do
      push_chat_session_patch(socket, sid)
    else
      socket
    end
  end

  defp maybe_push_new_session_patch(socket, _sid, false) do
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
        data: deserialize_event_data(evt["data"] || %{}),
        emitted_at: evt["emitted_at"]
      }

      SignalRouter.route(sock, signal, WorkspaceRegistry.all())
    end)
  end

  defp deserialize_event_data(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {safe_to_existing_atom(k), v} end)
  end

  defp resolve_mention_target(sid, target) do
    case Rho.Agent.Worker.whereis(target) do
      pid when is_pid(pid) -> {:ok, target}
      nil -> resolve_mention_by_role(sid, target)
    end
  end

  defp resolve_mention_by_role(sid, target) do
    role_atom = safe_to_existing_atom(target)

    if is_atom(role_atom) do
      case Rho.Agent.Registry.find_by_role(sid, role_atom) do
        [agent | _] -> {:ok, agent.agent_id}
        _ -> :error
      end
    else
      :error
    end
  end

  defp build_submit_content(content, image_parts, has_text) do
    if image_parts != [] do
      parts =
        if has_text do
          [ReqLLM.Message.ContentPart.text(content)]
        else
          []
        end

      parts ++ image_parts
    else
      content
    end
  end

  defp build_display_text(content, image_parts, has_text) do
    if image_parts != [] do
      img_label =
        "#{length(image_parts)} image#{if match?([_, _ | _], image_parts) do
          "s"
        end}"

      if has_text do
        "#{content}
[#{img_label} attached]"
      else
        "[#{img_label} attached]"
      end
    else
      content
    end
  end

  defp safe_to_existing_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end

  defp safe_to_existing_atom(str) do
    str
  end

  defp map_key?(map, key) do
    case Map.fetch(map, key) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp dt_initial_state do
    RhoWeb.Projections.DataTableProjection.init()
  end

  defp ensure_dt_keys(state) do
    defaults = dt_initial_state()
    Map.merge(defaults, state)
  end

  defp apply_data_table_event(socket, %{event: :table_changed} = data) do
    table_name = data[:table_name]
    state = read_dt_state(socket)

    cond do
      is_nil(table_name) ->
        refresh_data_table_session(socket)

      table_name != state.active_table ->
        refresh_data_table_tables(socket)

      stale_version?(data[:version], state.active_version) ->
        refresh_data_table_active(socket, table_name)

      true ->
        socket
    end
  end

  defp apply_data_table_event(socket, %{event: :table_created}) do
    refresh_data_table_session(socket)
  end

  defp apply_data_table_event(socket, %{event: :table_removed} = data) do
    removed = data[:table_name]
    state = read_dt_state(socket)
    socket = refresh_data_table_tables(socket)

    if state.active_table == removed do
      new_state = read_dt_state(socket)
      send(self(), {:data_table_switch_tab, pick_fallback_active_table(new_state)})
    end

    socket
  end

  defp apply_data_table_event(socket, %{event: :view_change} = data) do
    state = read_dt_state(socket)

    if is_binary(data[:table_name]) and data[:table_name] != state.active_table do
      send(self(), {:data_table_switch_tab, data[:table_name]})
    end

    metadata = data[:metadata] || %{}

    new_state = %{
      state
      | view_key: data[:view_key],
        mode_label: data[:mode_label],
        metadata: metadata
    }

    SignalRouter.write_ws_state(socket, :data_table, new_state)
  end

  defp apply_data_table_event(socket, _) do
    socket
  end

  defp stale_version?(version, current) do
    not (is_integer(version) and is_integer(current) and version <= current)
  end

  defp apply_open_workspace_event(socket, data) when is_map(data) do
    key = data[:key]

    cond do
      not is_atom(key) or is_nil(key) ->
        socket

      map_key?(socket.assigns.workspaces, key) ->
        socket
        |> assign(:active_workspace_id, key)
        |> assign(:shell, Shell.clear_activity(socket.assigns.shell, key))

      true ->
        case WorkspaceRegistry.get(key) do
          nil ->
            socket

          ws_mod ->
            socket = init_workspace(socket, key, ws_mod)

            if key == :data_table do
              refresh_data_table_session(socket)
            else
              socket
            end
        end
    end
  end

  defp apply_open_workspace_event(socket, _) do
    socket
  end

  defp refresh_data_table_session(socket) do
    sid = socket.assigns[:session_id]
    state = read_dt_state(socket)

    if is_nil(sid) do
      SignalRouter.write_ws_state(socket, :data_table, state)
    else
      refresh_dt_session_from_server(socket, sid, state)
    end
  end

  defp refresh_dt_session_from_server(socket, sid, state) do
    case Rho.Stdlib.DataTable.get_session_snapshot(sid) do
      %{tables: tables, table_order: order} ->
        previous_active = state.active_table

        state =
          %{state | tables: tables, table_order: order, error: nil}
          |> maybe_adopt_default_active()
          |> fetch_active_snapshot(sid)

        if state.active_table != previous_active do
          publish_view_focus(sid, state.active_table)
        end

        SignalRouter.write_ws_state(socket, :data_table, state)

      {:error, :not_running} ->
        SignalRouter.write_ws_state(socket, :data_table, %{state | error: :not_running})

      _ ->
        SignalRouter.write_ws_state(socket, :data_table, state)
    end
  end

  defp refresh_data_table_tables(socket) do
    sid = socket.assigns[:session_id]
    state = read_dt_state(socket)

    if is_nil(sid) do
      socket
    else
      case Rho.Stdlib.DataTable.get_session_snapshot(sid) do
        %{tables: tables, table_order: order} ->
          SignalRouter.write_ws_state(socket, :data_table, %{
            state
            | tables: tables,
              table_order: order
          })

        _ ->
          socket
      end
    end
  end

  defp refresh_data_table_active(socket, table_name) do
    sid = socket.assigns[:session_id]
    state = read_dt_state(socket)

    if is_nil(sid) or state.active_table != table_name do
      socket
    else
      socket = refresh_data_table_tables(socket)
      state = read_dt_state(socket)

      case Rho.Stdlib.DataTable.get_table_snapshot(sid, table_name) do
        {:ok, snap} ->
          new_state = %{state | active_snapshot: snap, active_version: snap.version, error: nil}
          SignalRouter.write_ws_state(socket, :data_table, new_state)

        {:error, :not_running} ->
          SignalRouter.write_ws_state(socket, :data_table, %{state | error: :not_running})

        {:error, :not_found} ->
          SignalRouter.write_ws_state(socket, :data_table, %{
            state
            | active_snapshot: nil,
              active_version: nil
          })

        _ ->
          socket
      end
    end
  end

  defp init_workspace(socket, key, ws_mod) do
    shell = socket.assigns.shell |> Shell.add_workspace(key) |> Shell.show_chat()

    socket
    |> assign(:workspaces, Map.put(socket.assigns.workspaces, key, ws_mod))
    |> assign(:ws_states, Map.put(socket.assigns.ws_states, key, ws_mod.projection().init()))
    |> assign(:active_workspace_id, key)
    |> assign(:shell, shell)
  end

  defp maybe_hydrate_workspace(socket, key, ws_mod) do
    if socket.assigns.session_id do
      hydrate_workspace(socket, socket.assigns.session_id, key, ws_mod)
    else
      socket
    end
  end

  defp read_dt_state(socket) do
    ensure_dt_keys(SignalRouter.read_ws_state(socket, :data_table) || dt_initial_state())
  end

  defp fetch_active_snapshot(state, sid) do
    case Rho.Stdlib.DataTable.get_table_snapshot(sid, state.active_table) do
      {:ok, snap} ->
        %{state | active_snapshot: snap, active_version: snap.version}

      {:error, :not_running} ->
        %{state | active_snapshot: nil, active_version: nil, error: :not_running}

      _ ->
        state
    end
  end

  defp load_library_into_data_table(socket, library_id) do
    sid = socket.assigns[:session_id]
    org_id = get_in(socket.assigns, [:current_organization, Access.key(:id)])

    lib =
      RhoFrameworks.Library.get_library(org_id, library_id) ||
        RhoFrameworks.Library.get_visible_library!(org_id, library_id)

    if is_nil(lib) do
      socket
    else
      load_library_rows_into_data_table(socket, sid, lib)
    end
  rescue
    _ -> socket
  end

  defp load_library_rows_into_data_table(socket, sid, lib) do
    table_name = "library:" <> lib.name
    schema = RhoFrameworks.DataTableSchemas.library_schema()
    _ = Rho.Stdlib.DataTable.ensure_started(sid)
    :ok = Rho.Stdlib.DataTable.ensure_table(sid, table_name, schema)
    parent = self()

    Task.start(fn ->
      rows = RhoFrameworks.Library.load_library_rows(lib.id)

      if rows != [] do
        Rho.Stdlib.DataTable.replace_all(sid, rows, table: table_name)
      end

      send(parent, {:library_load_complete, table_name, lib.name, lib.version, lib.immutable})
    end)

    version_label = library_version_label(lib.version, lib.immutable)

    state = ensure_dt_keys(SignalRouter.read_ws_state(socket, :data_table) || dt_initial_state())

    new_state = %{
      state
      | active_table: table_name,
        view_key: :skill_library,
        mode_label: "Skill Library — #{lib.name}#{version_label} (loading…)",
        metadata: library_workbench_metadata(lib, table_name)
    }

    if state.active_table != table_name do
      publish_view_focus(sid, table_name)
    end

    socket
    |> open_data_table_workspace()
    |> SignalRouter.write_ws_state(:data_table, new_state)
    |> refresh_data_table_session()
  rescue
    _ -> socket
  end

  defp library_version_label(version, _immutable?) when not is_nil(version), do: " v#{version}"
  defp library_version_label(_version, true), do: ""
  defp library_version_label(_version, _immutable?), do: " (draft)"

  defp library_workbench_metadata(lib, table_name) do
    %{
      workflow: :edit_existing,
      artifact_kind: :skill_library,
      title: "#{lib.name} Skill Framework",
      library_name: lib.name,
      output_table: table_name,
      library_id: lib.id,
      persisted?: true,
      published?: lib.immutable,
      dirty?: false,
      source_label: library_source_label(lib.version, lib.immutable)
    }
  end

  defp library_source_label(version, _immutable?) when not is_nil(version),
    do: "Loaded v#{version}"

  defp library_source_label(_version, true), do: "Loaded standard"
  defp library_source_label(_version, _immutable?), do: "Loaded draft"

  defp open_data_table_workspace(socket) do
    key = :data_table

    if map_key?(socket.assigns.workspaces, key) do
      socket |> assign(:active_workspace_id, key)
    else
      case WorkspaceRegistry.get(key) do
        nil ->
          socket

        ws_mod ->
          shell = socket.assigns.shell |> Shell.add_workspace(key) |> Shell.show_chat()

          socket
          |> assign(:workspaces, Map.put(socket.assigns.workspaces, key, ws_mod))
          |> assign(
            :ws_states,
            Map.put(socket.assigns.ws_states, key, ws_mod.projection().init())
          )
          |> assign(:active_workspace_id, key)
          |> assign(:shell, shell)
      end
    end
  end

  defp maybe_adopt_default_active(%{active_table: active, table_order: order} = state) do
    cond do
      is_binary(active) and active in order -> state
      "main" in order -> %{state | active_table: "main"}
      order != [] -> %{state | active_table: hd(order)}
      true -> state
    end
  end

  defp pick_fallback_active_table(%{table_order: order}) do
    cond do
      "main" in order -> "main"
      order != [] -> hd(order)
      true -> "main"
    end
  end

  defp publish_view_focus(nil, _table_name) do
    :ok
  end

  defp publish_view_focus(_sid, nil) do
    :ok
  end

  defp publish_view_focus(sid, table_name) when is_binary(sid) and is_binary(table_name) do
    row_count =
      case Rho.Stdlib.DataTable.summarize_table(sid, table: table_name) do
        {:ok, %{total_rows: n}} -> n
        _ -> 0
      end

    event = %Rho.Events.Event{
      kind: :view_focus,
      session_id: sid,
      agent_id: nil,
      timestamp: System.monotonic_time(:millisecond),
      data: %{table_name: table_name, row_count: row_count},
      source: :user
    }

    Rho.Events.broadcast(sid, event)
    :ok
  end

  defp update_selection(socket, state, table, %MapSet{} = new_set) do
    sid = socket.assigns[:session_id]
    ids = MapSet.to_list(new_set)

    if is_binary(sid) do
      Rho.Stdlib.DataTable.set_selection(sid, table, ids)
    end

    publish_row_selection(sid, table, ids)
    new_state = %{state | selections: Map.put(state.selections, table, new_set)}
    SignalRouter.write_ws_state(socket, :data_table, new_state)
  end

  defp publish_row_selection(nil, _table, _ids) do
    :ok
  end

  defp publish_row_selection(_sid, nil, _ids) do
    :ok
  end

  defp publish_row_selection(sid, table, ids)
       when is_binary(sid) and is_binary(table) and is_list(ids) do
    event = %Rho.Events.Event{
      kind: :row_selection,
      session_id: sid,
      agent_id: nil,
      timestamp: System.monotonic_time(:millisecond),
      data: %{table_name: table, row_ids: ids},
      source: :user
    }

    Rho.Events.broadcast(sid, event)
    :ok
  end

  defp determine_workspaces(_live_action) do
    %{}
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

  defp workbench_suggestions(%Rho.Stdlib.DataTable.WorkbenchContext{
         active_artifact: %Rho.Stdlib.DataTable.WorkbenchContext.ArtifactSummary{} = artifact
       }) do
    artifact.actions
    |> Enum.map(&workbench_suggestion(&1, artifact))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(3)
  end

  defp workbench_suggestions(_), do: []

  defp workbench_suggestion(:generate_levels, artifact) do
    suggestion(
      :generate_levels,
      "Generate proficiency levels for skills missing levels in #{artifact.table_name}."
    )
  end

  defp workbench_suggestion(:save_draft, artifact) do
    suggestion(:save_draft, "Save #{artifact.title} as a draft.")
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
    suggestion(:save_role_profile, "Save #{artifact.title}.")
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
        %{type: evt["type"], data: deserialize_event_data(evt["data"] || %{})}
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

  defp session_ensure_opts(:data_table) do
    [agent_name: :data_table, id_prefix: "sheet"]
  end

  defp session_ensure_opts(:chatroom) do
    [id_prefix: "chat"]
  end

  defp session_ensure_opts(_) do
    []
  end

  defp user_workspace(socket) do
    workspace_for_session(socket, socket.assigns[:session_id])
  end

  defp workspace_for_session(socket, sid) do
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

  defp refresh_threads(socket) do
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

  defp refresh_conversations(socket) do
    active_conversation = active_conversation(socket)
    active_id = active_conversation && active_conversation["id"]
    active_thread_id = active_conversation && active_conversation["active_thread_id"]
    active_messages = active_conversation_messages(socket)

    conversations =
      socket
      |> conversation_list_opts()
      |> Rho.Conversation.list()
      |> Enum.flat_map(&chat_rail_items(&1, active_id, active_thread_id, active_messages))
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

  defp chat_rail_items(conversation, active_id, active_thread_id, active_messages) do
    threads = conversation["threads"] || []

    case threads do
      [] ->
        [chat_rail_item(conversation, nil, active_id, active_thread_id, active_messages, false)]

      [_one] ->
        Enum.map(
          threads,
          &chat_rail_item(conversation, &1, active_id, active_thread_id, active_messages, false)
        )

      many ->
        Enum.map(
          many,
          &chat_rail_item(conversation, &1, active_id, active_thread_id, active_messages, true)
        )
    end
  end

  defp chat_rail_item(
         conversation,
         thread,
         active_id,
         active_thread_id,
         active_messages,
         threaded?
       ) do
    thread_id = thread && thread["id"]
    active = chat_row_active?(conversation["id"], thread_id, active_id, active_thread_id)

    messages =
      if active and active_messages != [] do
        active_messages
      else
        conversation_trace_messages(thread)
      end

    last_message = last_text_message(messages)
    last_user_message = last_text_message(messages, :user)
    updated_at = chat_row_updated_at(conversation, thread, active)

    %{
      id: chat_row_id(conversation, thread),
      conversation_id: conversation["id"],
      session_id: conversation["session_id"],
      thread_id: thread_id,
      agent_name: conversation_agent_name(conversation),
      title: chat_title(conversation, thread, last_user_message, threaded?),
      preview: conversation_preview(thread, last_message, conversation),
      updated_at: updated_at,
      updated_label: relative_time(updated_at),
      active: active
    }
  end

  defp chat_row_id(%{"id" => conversation_id}, %{"id" => thread_id}) do
    "#{conversation_id}:#{thread_id}"
  end

  defp chat_row_id(%{"id" => conversation_id}, _thread) do
    conversation_id
  end

  defp chat_row_updated_at(conversation, thread, true) do
    conversation["updated_at"] || (thread && thread["updated_at"])
  end

  defp chat_row_updated_at(conversation, thread, _active?) do
    (thread && thread["updated_at"]) || conversation["updated_at"]
  end

  defp conversation_trace_messages(%{"tape_name" => tape_name}) when is_binary(tape_name) do
    Rho.Trace.Projection.chat(tape_name, last: 80)
  rescue
    _ -> []
  end

  defp conversation_trace_messages(_thread) do
    []
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

  defp last_text_message(messages, role \\ nil) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn message ->
      role_match? = is_nil(role) or Map.get(message, :role) == role
      role_match? and conversation_message_text(message) != ""
    end)
  end

  defp conversation_title(%{"title" => title}, _thread, _message)
       when is_binary(title) and title not in ["", "New conversation"] do
    truncate_text(title, 48)
  end

  defp conversation_title(_conversation, _thread, message) when is_map(message) do
    message |> conversation_message_text() |> truncate_text(48)
  end

  defp conversation_title(_conversation, %{"name" => name}, _message)
       when is_binary(name) and name not in ["", "Main", "New Thread", "New chat"] do
    truncate_text(name, 48)
  end

  defp conversation_title(_conversation, _thread, _message) do
    "New chat"
  end

  defp chat_title(conversation, thread, message, threaded?) do
    cond do
      custom_conversation_title?(conversation) -> conversation_title(conversation, thread, nil)
      is_map(message) -> message |> conversation_message_text() |> truncate_text(48)
      not threaded? -> conversation_title(conversation, thread, nil)
      title = thread_title(thread) -> title
      true -> "New chat"
    end
  end

  defp custom_conversation_title?(%{"title" => title})
       when is_binary(title) and title not in ["", "New conversation"] do
    true
  end

  defp custom_conversation_title?(_conversation) do
    false
  end

  defp thread_title(%{"name" => name})
       when is_binary(name) and name not in ["", "Main", "New Thread", "New chat"] do
    truncate_text(name, 48)
  end

  defp thread_title(_thread) do
    nil
  end

  defp conversation_preview(_thread, message, _conversation) when is_map(message) do
    role =
      message
      |> Map.get(:role)
      |> case do
        :user -> "You"
        :assistant -> "Assistant"
        :system -> "System"
        _ -> "Message"
      end

    "#{role}: #{message |> conversation_message_text() |> truncate_text(70)}"
  end

  defp conversation_preview(%{"summary" => summary}, _message, _conversation)
       when is_binary(summary) and summary != "" do
    truncate_text(summary, 70)
  end

  defp conversation_preview(_thread, _message, conversation) do
    case conversation["title"] do
      title when is_binary(title) and title not in ["", "New conversation"] ->
        truncate_text(title, 70)

      _ ->
        "No messages yet"
    end
  end

  defp conversation_message_text(%{content: content}) do
    content_to_text(content)
  end

  defp conversation_message_text(%{"content" => content}) do
    content_to_text(content)
  end

  defp conversation_message_text(_) do
    ""
  end

  defp content_to_text(text) when is_binary(text) do
    text |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp content_to_text(text) when is_list(text) do
    text
    |> Enum.map_join(" ", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other when is_binary(other) -> other
      _ -> ""
    end)
    |> content_to_text()
  end

  defp content_to_text(text) when is_map(text) do
    text |> inspect(limit: 20) |> content_to_text()
  end

  defp content_to_text(_) do
    ""
  end

  defp truncate_text(nil, _max_value) do
    ""
  end

  defp truncate_text(text, max_value) when is_binary(text) do
    if String.length(text) > max_value do
      String.slice(text, 0, max_value) <> "..."
    else
      text
    end
  end

  defp relative_time(nil) do
    ""
  end

  defp relative_time(iso) when is_binary(iso) do
    with {:ok, dt, _} <- DateTime.from_iso8601(iso) do
      seconds = max(DateTime.diff(DateTime.utc_now(), dt, :second), 0)

      cond do
        seconds < 60 -> "now"
        seconds < 3600 -> "#{div(seconds, 60)}m"
        seconds < 86400 -> "#{div(seconds, 3600)}h"
        seconds < 604_800 -> "#{div(seconds, 86400)}d"
        true -> Calendar.strftime(dt, "%b %-d")
      end
    else
      _ -> ""
    end
  end

  defp can_access_conversation?(socket, conversation) do
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

  defp touch_active_conversation(socket) do
    case active_conversation(socket) do
      %{"id" => conversation_id} -> Rho.Conversation.touch(conversation_id)
      _ -> :ok
    end
  end

  defp refresh_conversation_event?(kind)
       when kind in [:message_sent, :turn_finished, :tool_start, :tool_result, :error] do
    true
  end

  defp refresh_conversation_event?(_kind) do
    false
  end

  defp filter_library_groups(groups, query) when is_binary(query) do
    case String.trim(query) do
      "" ->
        groups

      needle ->
        needle = String.downcase(needle)

        Enum.filter(groups, fn g ->
          String.contains?(String.downcase(g.name), needle) or
            Enum.any?(g.versions, fn lib ->
              String.contains?(String.downcase(lib.name), needle)
            end)
        end)
    end
  end

  defp filter_library_groups(groups, _) do
    groups
  end

  defp group_libraries(libraries) do
    libraries
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, versions} ->
      sorted = Enum.sort_by(versions, & &1.updated_at, {:desc, DateTime})
      primary = hd(sorted)

      %{
        name: name,
        description: primary.description,
        type: primary.type,
        primary: primary,
        versions: sorted,
        version_count: length(sorted)
      }
    end)
    |> Enum.sort_by(& &1.primary.updated_at, {:desc, DateTime})
  end

  defp group_skills(skills) do
    skills
    |> Enum.sort_by(fn s -> {s.category, s.cluster, s.name} end)
    |> Enum.group_by(fn s -> s.category || "Other" end)
    |> Enum.sort_by(fn {cat, _} -> cat end)
    |> Enum.map(fn {category, cat_skills} ->
      clusters =
        cat_skills
        |> Enum.group_by(fn s -> s.cluster || "General" end)
        |> Enum.sort_by(fn {cluster, _} -> cluster end)

      {category, clusters}
    end)
  end

  @doc false
  def refresh_skill_search(socket) do
    library = socket.assigns[:library]
    query = String.trim(socket.assigns[:skill_search_query] || "")

    cond do
      is_nil(library) ->
        Phoenix.Component.assign(socket, :skill_search_results, nil)

      query == "" ->
        Phoenix.Component.assign(socket, :skill_search_results, nil)

      true ->
        opts =
          case socket.assigns[:status_filter] do
            nil -> []
            status -> [status: status]
          end

        results = RhoFrameworks.Library.search_in_library(library.id, query, opts)
        Phoenix.Component.assign(socket, :skill_search_results, results)
    end
  end

  def group_skill_index(index) do
    index
    |> Enum.chunk_by(fn %{category: c} -> c end)
    |> Enum.map(fn rows ->
      raw_category = hd(rows).category

      clusters =
        Enum.map(rows, fn %{cluster: cl, count: n} -> {cl || "General", raw_category, cl, n} end)

      {raw_category || "Other", clusters}
    end)
  end

  defp group_roles_by_family(profiles) do
    profiles
    |> Enum.group_by(& &1.role_family)
    |> Enum.sort_by(fn {family, _} -> family || "" end)
  end

  defp group_role_skills(role_skills) do
    role_skills
    |> Enum.sort_by(fn rs -> {rs.skill.category, rs.skill.cluster, rs.skill.name} end)
    |> Enum.group_by(fn rs -> rs.skill.category || "Other" end)
    |> Enum.sort_by(fn {cat, _} -> cat end)
    |> Enum.map(fn {category, skills} ->
      clusters =
        skills
        |> Enum.group_by(fn rs -> rs.skill.cluster || "General" end)
        |> Enum.sort_by(fn {cluster, _} -> cluster end)

      {category, clusters}
    end)
  end

  defp role_subtitle(profile) do
    parts =
      [profile.role_family, profile.seniority_label, profile.description]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    if parts == [] do
      nil
    else
      Enum.join(parts, " - ")
    end
  end

  defp has_rich_fields?(profile) do
    Enum.any?(
      [
        profile.purpose,
        profile.accountabilities,
        profile.success_metrics,
        profile.qualifications,
        profile.reporting_context
      ],
      &(&1 != nil && &1 != "")
    )
  end

  defp format_suggest_flash([]) do
    "Suggest returned no skills."
  end

  defp format_suggest_flash(added) do
    count = length(added)

    "Added #{count} #{if count == 1 do
      "skill"
    else
      "skills"
    end}"
  end

  defp file_icon(_mime, name) do
    case Path.extname(name) |> String.downcase() do
      ".xlsx" -> "📊"
      ".csv" -> "📄"
      _ -> "📎"
    end
  end

  defp upload_error_msg(:too_large) do
    "File too large (max 10MB)"
  end

  defp upload_error_msg(:not_accepted) do
    "Only .xlsx / .csv / .pdf / .docx / text files supported"
  end

  defp upload_error_msg(:too_many_files) do
    "Too many files (max 5)"
  end

  defp upload_error_msg(other) do
    "Upload error: #{inspect(other)}"
  end
end
