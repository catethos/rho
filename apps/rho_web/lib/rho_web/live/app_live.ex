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

  # ── Mount ──────────────────────────────────────────────────────────

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
      |> assign(:selected_agent_id, nil)
      |> assign(:timeline_open, false)
      |> assign(:drawer_open, false)
      |> assign(:show_new_agent, false)
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
        accept: ~w(.xlsx .csv),
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
            socket
            |> SessionCore.subscribe_and_hydrate(session_id, ensure_opts)
          else
            {sid, socket} = SessionCore.ensure_session(socket, nil, ensure_opts)
            SessionCore.subscribe_and_hydrate(socket, sid, ensure_opts)
          end

        socket
        |> restore_from_snapshot()
        |> Welcome.maybe_render()
        |> refresh_threads()
        |> refresh_data_table_session()
      else
        socket
      end

    {:ok, socket}
  end

  # ── Handle Params (page switching) ─────────────────────────────────

  @impl true
  def handle_params(params, _uri, socket) do
    live_action = socket.assigns.live_action
    new_page = page_for_action(live_action)
    sid = params["session_id"]
    new_workspaces = determine_workspaces(live_action)
    current_sid = socket.assigns.session_id

    chat_context = extract_chat_context(params)

    socket =
      socket
      |> cleanup_previous_page(new_page)
      |> assign(:active_page, new_page)

    socket =
      cond do
        # Different session: full resubscribe
        sid && sid != current_sid && connected?(socket) ->
          case Rho.Agent.Primary.validate_session_id(sid) do
            :ok ->
              socket
              |> SessionCore.unsubscribe()
              |> assign(:session_id, sid)
              |> assign(:chat_context, chat_context)
              |> merge_workspaces(new_workspaces)
              |> SessionCore.subscribe_and_hydrate(sid, session_ensure_opts(live_action))
              |> refresh_data_table_session()

            _ ->
              socket
          end

        # Same session or no session param
        sid == current_sid || is_nil(sid) ->
          socket
          |> assign(:chat_context, chat_context)
          |> merge_workspaces(new_workspaces)

        true ->
          socket
      end

    # Load page-specific data
    socket = apply_page(socket, new_page, params)

    {:noreply, socket}
  end

  # ── Page-specific data loading ─────────────────────────────────────

  defp apply_page(socket, :libraries, _params) do
    if connected?(socket) do
      org = socket.assigns.current_organization
      libraries = RhoFrameworks.Library.list_libraries(org.id)

      socket
      |> assign(:libraries, libraries)
      |> assign(:library_groups, group_libraries(libraries))
      |> assign(:library_search_query, "")
      |> assign_new(:chat_overlay_open, fn -> false end)
      |> assign_new(:overlay_session_id, fn -> nil end)
      |> assign_new(:smart_entry_pending?, fn -> false end)
    else
      socket
      |> assign(:libraries, [])
      |> assign(:library_groups, [])
      |> assign(:library_search_query, "")
      |> assign_new(:chat_overlay_open, fn -> false end)
      |> assign_new(:overlay_session_id, fn -> nil end)
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
          "notes=#{div(t_notes - t_group, 1000)}ms " <>
          "total=#{div(t_notes - t0, 1000)}ms"
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
        for {raw_cat, _raw_cluster} <- Map.keys(cluster_skills),
            into: MapSet.new(),
            do: raw_cat

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
      |> assign_new(:chat_overlay_open, fn -> false end)
      |> assign_new(:overlay_session_id, fn -> nil end)
      |> maybe_open_chat_for_library(params["chat"])
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
      |> assign_new(:chat_overlay_open, fn -> false end)
      |> assign_new(:overlay_session_id, fn -> nil end)
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

  defp apply_page(socket, _page, _params), do: socket

  defp maybe_scroll_to_skill(socket, nil), do: socket

  defp maybe_scroll_to_skill(socket, skill_id) do
    push_event(socket, "scroll_to_skill", %{skill_id: skill_id})
  end

  defp maybe_open_chat_for_library(socket, "1"), do: assign(socket, :chat_overlay_open, true)
  defp maybe_open_chat_for_library(socket, _), do: socket

  # ── Page cleanup on navigation ─────────────────────────────────────

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
          socket
          |> assign(:profile, nil)
          |> assign(:role_skills_grouped, nil)

        :settings ->
          socket
          |> assign(:org_changeset, nil)
          |> assign(:user_changeset, nil)

        :members ->
          socket
          |> assign(:members, nil)
          |> assign(:invite_error, nil)

        _ ->
          socket
      end
    end
  end

  defp cleanup_libraries_page(socket) do
    if overlay_sid = socket.assigns[:overlay_session_id] do
      Rho.Events.unsubscribe(overlay_sid)
    end

    socket
    |> assign(:libraries, nil)
    |> assign(:library_search_query, "")
    |> assign(:chat_overlay_open, false)
    |> assign(:overlay_session_id, nil)
  end

  # ── Render ─────────────────────────────────────────────────────────

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

  # ── Chat page render (from SessionLive) ────────────────────────────

  defp render_chat(assigns) do
    active_id = assigns.active_agent_id
    active_messages = Map.get(assigns.agent_messages, active_id, [])
    active_agent = if active_id, do: Map.get(assigns.agents, active_id)

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
      Enum.map(overlay_keys, fn key ->
        {key, WorkspaceRegistry.get(key)}
      end)
      |> Enum.reject(fn {_key, mod} -> is_nil(mod) end)

    shared_ws_assigns = %{
      session_id: assigns.session_id,
      agents: assigns.agents,
      streaming: any_agent_busy?(assigns.agents),
      total_cost: assigns.total_cost
    }

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

    ~H"""
    <div id="session-root" phx-hook="CommandPalette" class={"session-layout #{if @has_workspaces, do: "workspace-mode", else: ""} #{if @drawer_open, do: "drawer-pinned", else: ""} #{if @debug_mode, do: "debug-mode", else: ""} #{if @shell.focus_workspace_id, do: "focus-mode", else: ""}"}>
      <.session_header
        session_id={@session_id}
        agents={@agents}
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
          compact={@has_workspaces}
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
          uploads={@uploads}
          active_agent={@active_agent}
          connected={@connected}
          threads={@threads}
          active_thread_id={@active_thread_id}
          files_parsing={@files_parsing}
        />

        <.debug_panel
          :if={@debug_mode}
          projections={@debug_projections}
          active_agent_id={@active_agent_id}
          session_id={@session_id}
        />
      </div>

      <.new_agent_dialog :if={@show_new_agent} session_id={@session_id} />

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
        threads={@threads}
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

  # ── Libraries page render ──────────────────────────────────────────

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
          <button phx-click="open_chat_overlay" class="btn-primary">
            + New Library
          </button>
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

      <.live_component
        module={RhoWeb.ChatOverlayComponent}
        id="chat-overlay"
        open={@chat_overlay_open}
        agent_name={:spreadsheet}
        intent="I'd like to create a new skill library for this organization. Please help me define it."
        current_user={@current_user}
        current_organization={@current_organization}
      />
    </.page_shell>
    """
  end

  # ── Library Show page render ───────────────────────────────────────

  defp render_library_show(assigns) do
    search_active? = String.trim(assigns[:skill_search_query] || "") != ""

    assigns =
      assigns
      |> assign(:skill_search_active?, search_active?)
      |> assign(
        :search_grouped,
        if(search_active?, do: group_skills(assigns[:skill_search_results] || []), else: [])
      )
      |> then(fn a ->
        assign(
          a,
          :filtered_skill_count,
          if(search_active?, do: length(a[:skill_search_results] || []), else: 0)
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
          <%= if @library.immutable do %>
            <button phx-click="open_chat_overlay" class="btn-secondary">
              Open in Chat
            </button>
          <% else %>
            <.link patch={~p"/orgs/#{@current_organization.slug}/chat?library_id=#{@library.id}"} class="btn-secondary">
              Open in Chat
            </.link>
          <% end %>
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

      <.live_component
        module={RhoWeb.ChatOverlayComponent}
        id="chat-overlay"
        open={@chat_overlay_open}
        agent_name={:spreadsheet}
        intent={library_chat_intent(@library)}
        current_user={@current_user}
        current_organization={@current_organization}
      />
    </.page_shell>
    """
  end

  defp library_chat_intent(nil), do: nil

  defp library_chat_intent(%{name: name, id: id}) do
    "I'm browsing the \"#{name}\" library (id: #{id}). " <>
      "Help me explore it. Use browse_library, find_skill, or find_similar_skills " <>
      "with this library_id when you need to look things up."
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

  # ── Roles page render ──────────────────────────────────────────────

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

  # ── Role Show page render ──────────────────────────────────────────

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

  # ── Settings page render ───────────────────────────────────────────

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

  # ── Members page render ────────────────────────────────────────────

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

  # ══════════════════════════════════════════════════════════════════
  # Events — Chat / Session
  # ══════════════════════════════════════════════════════════════════

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
      # Hoist session-ensure up so any upload-server start has a real session id.
      {sid, socket} =
        if socket.assigns.session_id do
          {socket.assigns.session_id, socket}
        else
          ensure_opts = session_ensure_opts(socket.assigns.live_action)
          {new_sid, socket} = SessionCore.ensure_session(socket, nil, ensure_opts)
          socket = SessionCore.subscribe_and_hydrate(socket, new_sid, ensure_opts)
          {new_sid, socket}
        end

      # Make sure the upload server is up — mount may have skipped this if
      # session_id was nil at connect-time.
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

      cond do
        file_handles == [] ->
          # Existing path — no files, send immediately.
          submit_to_session(socket, content, image_parts, has_text)

        true ->
          # Files present — defer submit until parses complete.
          socket = arm_parse_tasks(socket, content, image_parts, has_text, file_handles)
          {:noreply, socket}
      end
    end
  end

  def handle_event("select_tab", %{"agent-id" => agent_id}, socket) do
    {:noreply, assign(socket, :active_agent_id, agent_id)}
  end

  def handle_event("select_agent", %{"agent-id" => agent_id}, socket) do
    socket =
      socket
      |> assign(:selected_agent_id, agent_id)
      |> assign(:drawer_open, true)

    {:noreply, socket}
  end

  def handle_event("toggle_new_agent", _params, socket) do
    {:noreply, assign(socket, :show_new_agent, !socket.assigns.show_new_agent)}
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

    memory_mod = Rho.Config.tape_module()
    agent_ref = memory_mod.memory_ref(agent_id, File.cwd!())
    memory_mod.bootstrap(agent_ref)

    {:ok, _pid} =
      Rho.Agent.Supervisor.start_worker(
        agent_id: agent_id,
        session_id: sid,
        workspace: File.cwd!(),
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
      |> assign(:show_new_agent, false)
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
        pid when is_pid(pid) -> GenServer.stop(pid, :normal, 5_000)
        nil -> :ok
      end

      Rho.Agent.Registry.unregister(agent_id)

      new_tab_order = Enum.reject(socket.assigns.agent_tab_order, &(&1 == agent_id))
      new_agents = Map.delete(socket.assigns.agents, agent_id)

      active =
        if socket.assigns.active_agent_id == agent_id,
          do: primary_id,
          else: socket.assigns.active_agent_id

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

  # ── Workspace events ───────────────────────────────────────────────

  def handle_event("switch_workspace", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    if is_atom(key) and Map.has_key?(socket.assigns.workspaces, key) do
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

    if is_atom(key) and Map.has_key?(socket.assigns.shell.workspaces, key) do
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
        if ws_mod && !Map.has_key?(socket.assigns.workspaces, key) do
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

      Map.has_key?(socket.assigns.workspaces, key) ->
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

    if is_atom(key) and Map.has_key?(socket.assigns.workspaces, key) do
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

  # ── Thread events ──────────────────────────────────────────────────

  def handle_event("switch_thread", %{"thread_id" => thread_id}, socket) do
    sid = socket.assigns.session_id
    workspace = File.cwd!()

    current_thread = Threads.active(sid, workspace)

    if current_thread do
      snapshot = Snapshot.build_snapshot(socket)
      Snapshot.save(sid, workspace, snapshot, thread_id: current_thread["id"])
    end

    case Threads.switch(sid, workspace, thread_id) do
      :ok ->
        target = Threads.get(sid, workspace, thread_id)

        Rho.Agent.Primary.stop(sid)

        socket = SessionCore.unsubscribe(socket)

        start_opts = [tape_ref: target["tape_name"]]
        socket = SessionCore.subscribe_and_hydrate(socket, sid, start_opts)

        socket =
          case Snapshot.load(sid, workspace, thread_id: thread_id) do
            {:ok, snap} -> Snapshot.apply_snapshot(socket, snap)
            _ -> socket
          end

        {:noreply, refresh_threads(socket)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("fork_from_here", %{"message_index" => idx_str}, socket) do
    sid = socket.assigns.session_id
    workspace = File.cwd!()
    tape_module = Rho.Config.tape_module()

    primary_id = Rho.Agent.Primary.agent_id(sid)

    case Rho.Agent.Registry.get(primary_id) do
      %{tape_ref: tape_name} when is_binary(tape_name) ->
        Threads.init(sid, workspace, tape_name: tape_name)

      _ ->
        :ok
    end

    fork_point =
      case Integer.parse(idx_str) do
        {n, _} when n >= 0 -> n
        _ -> nil
      end

    current_thread = Threads.active(sid, workspace)

    if current_thread do
      snapshot = Snapshot.build_snapshot(socket)
      Snapshot.save(sid, workspace, snapshot, thread_id: current_thread["id"])
    end

    active_agent_id = socket.assigns.active_agent_id
    current_msgs = Map.get(socket.assigns.agent_messages, active_agent_id, [])

    forked_msgs =
      if fork_point do
        Enum.take(current_msgs, fork_point)
      else
        current_msgs
      end

    case Threads.fork_thread(sid, workspace, tape_module, fork_point: fork_point) do
      {:ok, thread} ->
        Rho.Agent.Primary.stop(sid)
        socket = SessionCore.unsubscribe(socket)
        start_opts = [tape_ref: thread["tape_name"]]
        socket = SessionCore.subscribe_and_hydrate(socket, sid, start_opts)

        new_agent_id = socket.assigns.active_agent_id
        agent_messages = Map.put(socket.assigns.agent_messages, new_agent_id, forked_msgs)
        socket = assign(socket, :agent_messages, agent_messages)

        fork_snapshot = Snapshot.build_snapshot(socket)
        Snapshot.save(sid, workspace, fork_snapshot, thread_id: thread["id"])

        {:noreply, refresh_threads(socket)}

      {:error, reason} ->
        require Logger
        Logger.warning("fork_from_here failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_event("new_blank_thread", _params, socket) do
    sid = socket.assigns.session_id
    workspace = File.cwd!()
    tape_module = Rho.Config.tape_module()

    tape_name = "#{sid}_thread_#{:erlang.unique_integer([:positive])}"
    tape_module.bootstrap(tape_name)

    case Threads.create(sid, workspace, %{"name" => "New Thread", "tape_name" => tape_name}) do
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
        {:noreply, refresh_threads(socket)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_thread", %{"thread_id" => thread_id}, socket) do
    sid = socket.assigns.session_id
    workspace = File.cwd!()

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
          _ -> socket
        end
      else
        socket
      end

    Threads.delete(sid, workspace, thread_id)
    {:noreply, refresh_threads(socket)}
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

  # ── Events — Libraries & Library Show pages (delegated) ───────────

  @library_events ~w(
    set_default_version delete_library set_default_version_from_show
    filter_status open_fork_modal close_fork_modal update_fork_name
    submit_fork fork_and_edit show_diff hide_diff
  )

  def handle_event(event, params, socket) when event in @library_events do
    RhoWeb.AppLive.LibraryEvents.handle_event(event, params, socket)
  end

  def handle_event("open_chat_overlay", _params, socket) do
    {:noreply, assign(socket, :chat_overlay_open, true)}
  end

  def handle_event("close_chat_overlay", _params, socket) do
    {:noreply, close_overlay(socket)}
  end

  # §3.5 Phase 9 — Smart NL entry from the libraries landing page.
  # Spawns the BAML classifier under TaskSupervisor and routes back to
  # `handle_info({:smart_entry_result, ...})` so the LV stays responsive
  # during the 1–3s round-trip.
  def handle_event("smart_entry_submit", %{"message" => msg}, socket)
      when is_binary(msg) and msg != "" do
    parent = self()
    classifier = match_flow_intent_mod()

    Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
      result =
        classifier.call(%{
          message: String.trim(msg),
          known_flows: known_flows_string()
        })

      send(parent, {:smart_entry_result, msg, result})
    end)

    {:noreply, assign(socket, :smart_entry_pending?, true)}
  end

  def handle_event("smart_entry_submit", _params, socket), do: {:noreply, socket}

  # ── Events — Roles & Settings pages (delegated) ──────────────────

  def handle_event("search_libraries", %{"q" => q}, socket) do
    {:noreply, assign(socket, :library_search_query, q)}
  end

  def handle_event("search_skills", %{"q" => q}, socket) do
    socket =
      socket
      |> assign(:skill_search_query, q)
      |> refresh_skill_search()

    {:noreply, socket}
  end

  def handle_event("toggle_category", %{"category" => cat}, socket) do
    raw_cat = if cat == "", do: nil, else: cat
    open = socket.assigns.open_categories

    open =
      if MapSet.member?(open, raw_cat),
        do: MapSet.delete(open, raw_cat),
        else: MapSet.put(open, raw_cat)

    {:noreply, assign(socket, :open_categories, open)}
  end

  def handle_event("load_cluster", %{"category" => cat, "cluster" => cluster}, socket) do
    library_id = socket.assigns.library.id
    raw_cat = if cat == "", do: nil, else: cat
    raw_cluster = if cluster == "", do: nil, else: cluster
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
       socket
       |> assign(:cluster_skills, cache)
       |> assign(:open_clusters, MapSet.put(open, key))}
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
            results =
              RhoFrameworks.Roles.find_similar_roles_semantic(org_id, query, limit: 50)

            %{query: query, results: results}
          end)

        {:noreply, socket}
    end
  end

  @settings_events ~w(delete_role save_org save_profile delete_org)

  def handle_event(event, params, socket) when event in @settings_events do
    RhoWeb.AppLive.SettingsEvents.handle_event(event, params, socket)
  end

  # ── Events — Members page (delegated) ────────────────────────────

  @member_events ~w(invite change_role remove_member transfer_ownership)

  def handle_event(event, params, socket) when event in @member_events do
    RhoWeb.AppLive.MemberEvents.handle_event(event, params, socket)
  end

  # ── File upload parse pipeline helpers ───────────────────────────

  # Lifted from the original send_message body. Used both for the
  # no-files fast path and the post-parse submit.
  defp submit_to_session(socket, content, image_parts, has_text) do
    submit_content = build_submit_content(content, image_parts, has_text)
    display_text = build_display_text(content, image_parts, has_text)
    SessionCore.send_message(socket, display_text, submit_content: submit_content)
  end

  defp arm_parse_tasks(socket, content, image_parts, has_text, file_handles) do
    sid = socket.assigns.session_id

    parsing =
      file_handles
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
      observations: %{}
    }

    socket
    |> assign(:files_parsing, parsing)
    |> assign(:files_pending_send, pending)
  end

  defp submit_with_uploads(socket) do
    pending = socket.assigns.files_pending_send

    enriched_text = build_enriched_message(pending.content, pending.observations)
    enriched_has_text = enriched_text != ""

    socket = assign(socket, :files_pending_send, nil)
    submit_to_session(socket, enriched_text, pending.image_parts, enriched_has_text)
  end

  defp build_enriched_message(content, observations) do
    blocks =
      observations
      |> Map.values()
      |> Enum.map(fn
        {handle, {:ok, obs}} ->
          obs.summary_text <> "\n[upload_id: #{handle.id}]"

        {handle, {:error, reason}} ->
          "[Upload error: #{handle.filename}: #{format_parse_error(reason)}]"
      end)
      |> Enum.join("\n\n")

    if content == "", do: blocks, else: content <> "\n\n" <> blocks
  end

  defp format_parse_error(:parse_timeout), do: "parsing exceeded 15s"
  defp format_parse_error({:parse_crashed, reason}), do: "parser crashed (#{inspect(reason)})"
  defp format_parse_error({:io_error, reason}), do: "I/O error (#{inspect(reason)})"
  defp format_parse_error(other), do: inspect(other)

  # ── Async — semantic role search backfill ────────────────────────

  @impl true
  def handle_async(:semantic_search, {:ok, %{query: q, results: results}}, socket) do
    if socket.assigns.role_search_query == q do
      {:noreply,
       socket
       |> assign(:role_search_results, results)
       |> assign(:role_search_pending?, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:semantic_search, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :role_search_pending?, false)}
  end

  # ── Async — library fork (skills copy + HNSW index updates can take
  # ~15s for ESCO-sized libraries; runs in a Task so the LV stays
  # responsive and the user sees a "Forking…" flash immediately) ──────

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

  # ── Private event helpers ─────────────────────────────────────────

  # §3.5 Phase 9 — Routes the BAML classifier's result. High-confidence
  # known-flow → push_navigate to the wizard with intake prefilled in
  # the query string. Low-confidence or unknown → flash and stay put.
  @smart_entry_min_confidence 0.5

  defp dispatch_smart_entry_result(socket, _message, {:ok, %{flow_id: flow_id} = result}) do
    confidence = Map.get(result, :confidence, 0.0)

    case RhoFrameworks.Flows.Registry.get(flow_id) do
      {:ok, _flow_mod} when confidence >= @smart_entry_min_confidence ->
        org = socket.assigns.current_organization
        query = build_intake_query(result, org.id)

        url =
          if query == "",
            do: "/orgs/#{org.slug}/flows/#{flow_id}",
            else: "/orgs/#{org.slug}/flows/#{flow_id}?#{query}"

        socket
        |> assign(:smart_entry_pending?, false)
        |> push_navigate(to: url)

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

  # §3.5 Phase 10d/10e — `starting_point` is whitelist-validated before it
  # reaches the URL (Iron Law #10: never `String.to_atom` an LLM string).
  # `library_hints` never enters the URL directly; each hint is resolved
  # against the org's libraries. A singleton becomes `library_id`
  # (extend_existing); a pair becomes `library_id_a` + `library_id_b`
  # (merge).
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
    libraries = if is_binary(org_id), do: RhoFrameworks.Library.list_libraries(org_id), else: []
    resolved = resolve_library_hints(hints, libraries)

    case resolved do
      [id] -> [{"library_id", id} | pairs]
      [id_a, id_b] -> [{"library_id_a", id_a}, {"library_id_b", id_b} | pairs]
      _ -> pairs
    end
  end

  # Resolve each hint against the org's libraries. Case-insensitive
  # substring with a uniqueness guard per hint — multiple matches or no
  # match → drop just that hint (a wrong pre-pick is harder to undo
  # than a missing one). Returns a list of ids in the same order as
  # the hints, with unresolved hints filtered out.
  defp resolve_library_hints(hints, libraries) when is_list(hints) do
    Enum.flat_map(hints, fn hint -> List.wrap(resolve_one_hint(hint, libraries)) end)
  end

  defp resolve_library_hints(_, _), do: []

  defp resolve_one_hint(hint, libraries) when is_binary(hint) and hint != "" do
    hint_down = String.downcase(hint)

    matches =
      Enum.filter(libraries, fn %{name: name} -> String.downcase(name) =~ hint_down end)

    case matches do
      [%{id: id}] -> id
      _ -> nil
    end
  end

  defp resolve_one_hint(_, _), do: nil

  defp match_flow_intent_mod do
    Application.get_env(:rho_web, :match_flow_intent_mod, RhoFrameworks.LLM.MatchFlowIntent)
  end

  defp known_flows_string do
    """
    - create-framework — Build a brand-new skill framework from scratch (with optional similar-role lookup or domain research). Use when the user wants to design or generate a new framework.
    - edit-framework — Edit an existing framework in place: tweak skill names, descriptions, categories, then save back to the same library. Use when the user wants to change/update/fix/edit one of their existing frameworks. Requires a library_hint naming which framework to edit.
    """
  end

  defp maybe_consume_avatar(socket) do
    entry = List.first(socket.assigns.uploads.avatar.entries)

    if entry && entry.done? do
      [{binary, media_type}] =
        consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
          {:ok, {File.read!(path), entry.client_type || "image/png"}}
        end)

      SessionCore.save_avatar(binary, media_type)
      data_uri = "data:#{media_type};base64,#{Base.encode64(binary)}"
      assign(socket, :user_avatar, data_uri)
    else
      socket
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Handle Info — Signal Bus & Session Messages
  # ══════════════════════════════════════════════════════════════════

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

          if active,
            do: assign(socket, :shell, Shell.enter_focus(socket.assigns.shell, active)),
            else: socket

        "exit_focus" ->
          assign(socket, :shell, Shell.exit_focus(socket.assigns.shell))

        "open_workspace:" <> key_str ->
          key = safe_to_existing_atom(key_str)
          if is_atom(key), do: assign(socket, :active_workspace_id, key), else: socket

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

  def handle_info({:data_table_switch_tab, name}, socket) do
    sid = socket.assigns.session_id
    state = ensure_dt_keys(SignalRouter.read_ws_state(socket, :data_table) || dt_initial_state())

    if name != state.active_table, do: publish_view_focus(sid, name)

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
      if MapSet.member?(current, id),
        do: MapSet.delete(current, id),
        else: MapSet.put(current, id)

    {:noreply, update_selection(socket, state, table, new_set)}
  end

  def handle_info({:data_table_toggle_all, table, visible_ids}, socket) do
    state = read_dt_state(socket)
    current = Map.get(state.selections, table, MapSet.new())
    visible = MapSet.new(visible_ids)
    all_selected? = visible != MapSet.new() and MapSet.subset?(visible, current)

    new_set =
      if all_selected?,
        do: MapSet.difference(current, visible),
        else: MapSet.union(current, visible)

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

  def handle_info({:library_load_complete, table_name, lib_name, lib_version}, socket) do
    state = ensure_dt_keys(SignalRouter.read_ws_state(socket, :data_table) || dt_initial_state())

    if state.active_table == table_name do
      version_label = if lib_version, do: " v#{lib_version}", else: " (draft)"
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

    cond do
      is_nil(org) or is_nil(session_id) ->
        send(self(), {:data_table_flash, "Suggest unavailable: no active session."})
        {:noreply, socket}

      true ->
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

    expand_groups =
      added
      |> Enum.map(fn s -> {s.category, s.cluster} end)
      |> Enum.uniq()

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

  # ── Chat overlay signals (Libraries page) ──────────────────────────

  def handle_info({:chat_overlay_started, session_id}, socket) do
    Rho.Events.subscribe(session_id)
    Rho.Stdlib.DataTable.ensure_started(session_id)

    {:noreply,
     socket
     |> assign(:overlay_session_id, session_id)}
  end

  def handle_info({:chat_overlay_closed, _session_id}, socket) do
    {:noreply, close_overlay(socket)}
  end

  # ── LiveEvents ────────────────────────────────────────────────────

  @impl true
  def handle_info(%LiveEvent{} = event, socket) do
    sid = socket.assigns.session_id

    # Forward to page-specific components when applicable
    if socket.assigns.active_page in [:libraries, :library_show] &&
         socket.assigns[:chat_overlay_open] do
      send_update(RhoWeb.ChatOverlayComponent, id: "chat-overlay", signal: event)
    end

    # Always update session state regardless of active page
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
                    "kind=#{event.kind} agent_id=#{event.agent_id}\n" <>
                    Exception.format(:error, e, __STACKTRACE__)
                )

                socket
            end

          {:noreply, socket}
      end
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

  # Upload parse task completed successfully.
  # Process.demonitor/2 drains the :DOWN message so the crash-handler below
  # is not triggered for normal task exit.
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

  # Upload parse task crashed — synthesize an error observation so the
  # message still goes through with an error note instead of being lost.
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when is_reference(ref) do
    case Map.pop(socket.assigns.files_parsing, ref) do
      {nil, _} ->
        {:noreply, socket}

      {%{handle_id: hid, filename: fname}, parsing} ->
        require Logger
        Logger.warning("Upload parse task crashed for #{fname}: #{inspect(reason)}")

        pending = socket.assigns.files_pending_send

        # Synthesize a crash result so the message still goes through.
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

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # Clean up overlay subscriptions
    if overlay_sid = socket.assigns[:overlay_session_id] do
      Rho.Events.unsubscribe(overlay_sid)
    end

    if sid = socket.assigns[:session_id] do
      snapshot = Snapshot.build_snapshot(socket)
      Snapshot.save(sid, File.cwd!(), snapshot)
    end

    :ok
  end

  # ══════════════════════════════════════════════════════════════════
  # Private Component Functions
  # ══════════════════════════════════════════════════════════════════

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

  defp session_header(assigns) do
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

  # --- Workspace tab bar ---

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

  # --- Workspace overlay ---

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

  # --- Thread picker ---

  attr(:threads, :list, required: true)
  attr(:active_thread_id, :string, default: nil)

  defp thread_picker(assigns) do
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
            &times;
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
  attr(:files_parsing, :map, default: %{})

  defp chat_side_panel(assigns) do
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
          <label class="chat-attach-button" title="Attach .xlsx / .csv">
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
    """
  end

  # --- New agent dialog ---

  attr(:session_id, :string, default: nil)

  defp new_agent_dialog(assigns) do
    roles = Rho.AgentConfig.agent_names()

    parent_options =
      if assigns.session_id do
        Rho.Agent.Registry.list_all(assigns[:session_id])
        |> Enum.map(fn info -> {info.agent_id, tab_label_from_info(info)} end)
        |> Enum.sort_by(fn {id, _} -> id end)
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
        </form>
        <button class="modal-cancel" phx-click="toggle_new_agent">Cancel</button>
      </div>
    </div>
    """
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

  # --- Debug panel ---

  attr(:projections, :map, required: true)
  attr(:active_agent_id, :string, default: nil)
  attr(:session_id, :string, default: nil)

  defp debug_panel(assigns) do
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

  defp debug_content_string(content) when is_binary(content), do: content
  defp debug_content_string(other), do: inspect(other, limit: :infinity)

  # ══════════════════════════════════════════════════════════════════
  # Private Helpers
  # ══════════════════════════════════════════════════════════════════

  defp page_for_action(:new), do: :chat
  defp page_for_action(:show), do: :chat
  defp page_for_action(:chat_new), do: :chat
  defp page_for_action(:chat_show), do: :chat
  defp page_for_action(:libraries), do: :libraries
  defp page_for_action(:library_show), do: :library_show
  defp page_for_action(:roles), do: :roles
  defp page_for_action(:role_show), do: :role_show
  defp page_for_action(:settings), do: :settings
  defp page_for_action(:members), do: :members
  defp page_for_action(_), do: :chat

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

  defp truncate_id(id) when byte_size(id) > 16, do: String.slice(id, 0, 16) <> "..."
  defp truncate_id(id), do: id

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"

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

  @doc false
  def append_message(socket, msg) do
    RhoWeb.Session.SignalRouter.append_message(socket, msg)
  end

  defp restore_from_snapshot(socket) do
    sid = socket.assigns[:session_id]

    if sid do
      case Snapshot.load(sid, File.cwd!()) do
        {:ok, snapshot} ->
          socket
          |> Snapshot.apply_snapshot(snapshot)
          |> tail_replay(sid, snapshot[:snapshot_at])

        _no_snapshot ->
          socket
      end
    else
      socket
    end
  end

  defp tail_replay(socket, _sid, nil), do: socket

  defp tail_replay(socket, sid, since_ms) when is_integer(since_ms) do
    {events, _last_seq} = Rho.Agent.EventLog.read(sid, limit: 10_000)

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
      parts = if has_text, do: [ReqLLM.Message.ContentPart.text(content)], else: []
      parts ++ image_parts
    else
      content
    end
  end

  defp build_display_text(content, image_parts, has_text) do
    if image_parts != [] do
      img_label = "#{length(image_parts)} image#{if length(image_parts) > 1, do: "s"}"
      if has_text, do: "#{content}\n[#{img_label} attached]", else: "[#{img_label} attached]"
    else
      content
    end
  end

  defp safe_to_existing_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end

  defp safe_to_existing_atom(other), do: other

  # --- DataTable helpers ---

  defp dt_initial_state, do: RhoWeb.Projections.DataTableProjection.init()

  # Backfill keys added after initial state shape (e.g. :error, :metadata)
  # so stale ws_state maps don't crash on struct-update syntax.
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

  defp apply_data_table_event(socket, _), do: socket

  defp stale_version?(version, current) do
    not (is_integer(version) and is_integer(current) and version <= current)
  end

  defp apply_open_workspace_event(socket, data) when is_map(data) do
    key = data[:key]

    cond do
      not is_atom(key) or is_nil(key) ->
        socket

      Map.has_key?(socket.assigns.workspaces, key) ->
        socket
        |> assign(:active_workspace_id, key)
        |> assign(:shell, Shell.clear_activity(socket.assigns.shell, key))

      true ->
        case WorkspaceRegistry.get(key) do
          nil ->
            socket

          ws_mod ->
            socket = init_workspace(socket, key, ws_mod)
            if key == :data_table, do: refresh_data_table_session(socket), else: socket
        end
    end
  end

  defp apply_open_workspace_event(socket, _), do: socket

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

        if state.active_table != previous_active,
          do: publish_view_focus(sid, state.active_table)

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
    shell =
      socket.assigns.shell
      |> Shell.add_workspace(key)
      |> Shell.show_chat()

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

    cond do
      is_nil(lib) ->
        socket

      # Immutable libraries (ESCO, public frameworks) can have ~14k rows;
      # dumping them into the per-session DataTable freezes the browser
      # tab and pins memory in the GenServer. Redirect to the existing
      # browse view (lazy index/cluster), and open the chat overlay
      # alongside via ?chat=1.
      lib.immutable ->
        slug = get_in(socket.assigns, [:current_organization, Access.key(:slug)])
        push_navigate(socket, to: ~p"/orgs/#{slug}/libraries/#{lib.id}?chat=1")

      true ->
        load_mutable_library_into_data_table(socket, sid, lib)
    end
  rescue
    _ -> socket
  end

  defp load_mutable_library_into_data_table(socket, sid, lib) do
    table_name = "library:" <> lib.name
    schema = RhoFrameworks.DataTableSchemas.library_schema()

    _ = Rho.Stdlib.DataTable.ensure_started(sid)
    :ok = Rho.Stdlib.DataTable.ensure_table(sid, table_name, schema)

    # The heavy row load + replace_all can take several seconds for large
    # libraries (e.g. ~14k-row ESCO copies). Run it in a Task so the chat
    # workspace renders immediately. The DataTable.Server publishes
    # :table_changed when replace_all lands, and the LV's existing event
    # handler refreshes the snapshot then. We post :library_load_complete
    # back so the mode label can drop "(loading…)".
    parent = self()

    Task.start(fn ->
      rows = RhoFrameworks.Library.load_library_rows(lib.id)
      if rows != [], do: Rho.Stdlib.DataTable.replace_all(sid, rows, table: table_name)
      send(parent, {:library_load_complete, table_name, lib.name, lib.version})
    end)

    version_label = if lib.version, do: " v#{lib.version}", else: " (draft)"

    state =
      ensure_dt_keys(SignalRouter.read_ws_state(socket, :data_table) || dt_initial_state())

    new_state = %{
      state
      | active_table: table_name,
        view_key: :skill_library,
        mode_label: "Skill Library — #{lib.name}#{version_label} (loading…)"
    }

    if state.active_table != table_name, do: publish_view_focus(sid, table_name)

    socket
    |> open_data_table_workspace()
    |> SignalRouter.write_ws_state(:data_table, new_state)
    |> refresh_data_table_session()
  rescue
    _ -> socket
  end

  defp open_data_table_workspace(socket) do
    key = :data_table

    if Map.has_key?(socket.assigns.workspaces, key) do
      socket
      |> assign(:active_workspace_id, key)
    else
      case WorkspaceRegistry.get(key) do
        nil ->
          socket

        ws_mod ->
          shell =
            socket.assigns.shell
            |> Shell.add_workspace(key)
            |> Shell.show_chat()

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

  defp publish_view_focus(nil, _table_name), do: :ok
  defp publish_view_focus(_sid, nil), do: :ok

  defp publish_view_focus(sid, table_name)
       when is_binary(sid) and is_binary(table_name) do
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

    # Write directly to the server so the agent's `prompt_sections/2` sees
    # the selection on the next turn. The PubSub broadcast + listener
    # bridge has a race: the listener only subscribes between
    # `:agent_started` and `:agent_stopped`, so clicks during the
    # between-turn gap would otherwise be lost.
    if is_binary(sid), do: Rho.Stdlib.DataTable.set_selection(sid, table, ids)

    publish_row_selection(sid, table, ids)

    new_state = %{state | selections: Map.put(state.selections, table, new_set)}
    SignalRouter.write_ws_state(socket, :data_table, new_state)
  end

  defp publish_row_selection(nil, _table, _ids), do: :ok
  defp publish_row_selection(_sid, nil, _ids), do: :ok

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

  defp determine_workspaces(_live_action), do: %{}

  defp chat_panel_mode(assigns) do
    cond do
      assigns.active_workspace_id == :chatroom -> :hidden
      map_size(assigns.workspaces) == 0 -> :expanded
      true -> assigns.shell.chat_mode
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
    {events, _last_seq} = Rho.Agent.EventLog.read(sid, limit: 10_000)
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
        Enum.reduce(Map.keys(added), socket.assigns.shell, fn key, sh ->
          Shell.add_workspace(sh, key)
        end)

      socket
      |> assign(:workspaces, merged_ws)
      |> assign(:shell, shell)
    end
  end

  defp session_ensure_opts(:data_table), do: [agent_name: :data_table, id_prefix: "sheet"]
  defp session_ensure_opts(:chatroom), do: [id_prefix: "chat"]
  defp session_ensure_opts(_), do: []

  defp extract_chat_context(params) do
    %{}
    |> maybe_put("library_id", params["library_id"])
    |> maybe_put("context", params["context"])
    |> maybe_put("role_profile_name", params["role_profile_name"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value) when is_binary(value), do: Map.put(map, key, value)

  defp refresh_threads(socket) do
    sid = socket.assigns[:session_id]

    if sid do
      threads = Threads.list(sid, File.cwd!())
      active = Threads.active(sid, File.cwd!())

      socket
      |> assign(:threads, threads)
      |> assign(:active_thread_id, active && active["id"])
    else
      socket
    end
  end

  defp close_overlay(socket) do
    if overlay_sid = socket.assigns[:overlay_session_id] do
      Rho.Events.unsubscribe(overlay_sid)
    end

    org = socket.assigns.current_organization
    libraries = RhoFrameworks.Library.list_libraries(org.id)

    socket
    |> assign(:chat_overlay_open, false)
    |> assign(:overlay_session_id, nil)
    |> assign(:libraries, libraries)
    |> assign(:library_groups, group_libraries(libraries))
  end

  # --- Page-specific grouping helpers ---

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

  defp filter_library_groups(groups, _), do: groups

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

  # Index rows are %{category, cluster, count} already sorted by [category, cluster].
  # Returns [{category_label, [{cluster_label, raw_category, raw_cluster, count}]}]
  # where the `raw_*` values preserve nil so on-demand loading can match the DB row exactly.
  def group_skill_index(index) do
    index
    |> Enum.chunk_by(fn %{category: c} -> c end)
    |> Enum.map(fn rows ->
      raw_category = hd(rows).category

      clusters =
        Enum.map(rows, fn %{cluster: cl, count: n} ->
          {cl || "General", raw_category, cl, n}
        end)

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

    if parts == [], do: nil, else: Enum.join(parts, " - ")
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

  defp format_suggest_flash([]), do: "Suggest returned no skills."

  defp format_suggest_flash(added) do
    count = length(added)
    "Added #{count} #{if count == 1, do: "skill", else: "skills"}"
  end

  defp file_icon(_mime, name) do
    case Path.extname(name) |> String.downcase() do
      ".xlsx" -> "📊"
      ".csv" -> "📄"
      _ -> "📎"
    end
  end

  defp upload_error_msg(:too_large), do: "File too large (max 10MB)"
  defp upload_error_msg(:not_accepted), do: "Only .xlsx / .csv supported"
  defp upload_error_msg(:too_many_files), do: "Too many files (max 5)"
  defp upload_error_msg(other), do: "Upload error: #{inspect(other)}"
end
