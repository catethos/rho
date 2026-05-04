defmodule RhoWeb.SessionLive do
  @moduledoc """
  Main LiveView — single state owner for the entire session UI.
  Subscribes via LiveEvents and projects all events into assigns.
  """
  use Phoenix.LiveView

  require Logger

  import RhoWeb.SignalComponents
  import RhoWeb.SessionLive.LayoutComponents

  alias RhoWeb.Session.SessionCore
  alias RhoWeb.Session.Shell
  alias RhoWeb.Session.SignalRouter
  alias RhoWeb.Session.Snapshot
  alias RhoWeb.Session.Threads
  alias RhoWeb.SessionLive.DataTableHelpers
  alias Rho.Events.Event, as: LiveEvent
  alias RhoWeb.Workspace.Registry, as: WorkspaceRegistry

  @impl true
  def mount(params, _session, socket) do
    session_id = SessionCore.validate_session_id(params["session_id"])
    live_action = socket.assigns[:live_action]
    active_page = :chat

    workspaces = determine_workspaces(live_action)
    # Always init projection state for the full registry so closed workspaces can project
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
      |> allow_upload(:images,
        accept: ~w(.jpg .jpeg .png .gif .webp),
        max_entries: 5,
        max_file_size: 10_000_000
      )
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

        # Restore snapshot + tail replay for catch-up
        socket
        |> restore_from_snapshot()
        |> refresh_threads()
        |> refresh_data_table_session()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    live_action = socket.assigns.live_action
    sid = params["session_id"]
    new_workspaces = determine_workspaces(live_action)
    current_sid = socket.assigns.session_id

    # Extract context query params for chat handoff
    chat_context = extract_chat_context(params)

    socket =
      cond do
        # Different session: full resubscribe
        sid && sid != current_sid && connected?(socket) ->
          case Rho.Agent.Primary.validate_session_id(sid) do
            :ok ->
              active_page = :chat

              socket
              |> SessionCore.unsubscribe()
              |> assign(:session_id, sid)
              |> assign(:active_page, active_page)
              |> assign(:chat_context, chat_context)
              |> merge_workspaces(new_workspaces)
              |> SessionCore.subscribe_and_hydrate(sid, session_ensure_opts(live_action))
              |> refresh_data_table_session()

            _ ->
              socket
          end

        # Same session, different live_action: add workspace, switch to it (no remount)
        sid == current_sid || is_nil(sid) ->
          socket
          |> assign(:chat_context, chat_context)
          |> merge_workspaces(new_workspaces)

        true ->
          socket
      end

    {:noreply, socket}
  end

  # --- Events from browser ---

  @impl true
  def handle_event("send_message", %{"content" => content}, socket) do
    content = String.trim(content)

    # Consume uploaded images
    image_parts =
      consume_uploaded_entries(socket, :images, fn %{path: path}, entry ->
        binary = File.read!(path)
        media_type = entry.client_type || "image/png"
        {:ok, ReqLLM.Message.ContentPart.image(binary, media_type)}
      end)

    has_images = image_parts != []
    has_text = content != ""

    if not has_text and not has_images do
      {:noreply, socket}
    else
      {sid, socket} =
        if socket.assigns.session_id do
          {socket.assigns.session_id, socket}
        else
          ensure_opts = session_ensure_opts(socket.assigns.live_action)
          {new_sid, socket} = SessionCore.ensure_session(socket, nil, ensure_opts)
          socket = SessionCore.subscribe_and_hydrate(socket, new_sid, ensure_opts)
          {new_sid, socket}
        end

      _ = sid

      submit_content = build_submit_content(content, image_parts, has_text)
      display_text = build_display_text(content, image_parts, has_text)

      SessionCore.send_message(socket, display_text, submit_content: submit_content)
    end
  end

  # --- Tab selection ---

  def handle_event("select_tab", %{"agent-id" => agent_id}, socket) do
    {:noreply, assign(socket, :active_agent_id, agent_id)}
  end

  # --- Agent sidebar selection (opens drawer) ---

  def handle_event("select_agent", %{"agent-id" => agent_id}, socket) do
    socket =
      socket
      |> assign(:selected_agent_id, agent_id)
      |> assign(:drawer_open, true)

    {:noreply, socket}
  end

  # --- New agent ---

  def handle_event("toggle_new_agent", _params, socket) do
    {:noreply, assign(socket, :show_new_agent, !socket.assigns.show_new_agent)}
  end

  def handle_event("create_agent", %{"role" => role} = params, socket) do
    # Auto-create session if none exists
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

    known_roles = Rho.AgentConfig.agent_names()

    role_atom =
      Enum.find(known_roles, :worker, fn name ->
        Atom.to_string(name) == role
      end)

    # Give each UI-created agent its own tape so conversations are independent
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

    # Eagerly add the agent to tab state so the tab renders immediately
    # rather than waiting for the async rho.agent.started signal.
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

    {:noreply, socket}
  end

  def handle_event("remove_agent", %{"agent-id" => agent_id}, socket) do
    primary_id = SessionCore.primary_agent_id(socket.assigns.session_id)

    # Never allow removing the primary agent
    if agent_id == primary_id do
      {:noreply, socket}
    else
      # Stop the worker process if alive
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
    # Auto-consume avatar uploads when they arrive
    socket =
      with [entry | _] <- socket.assigns.uploads.avatar.entries,
           true <- entry.done? do
        [{binary, media_type}] =
          consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
            {:ok, {File.read!(path), entry.client_type || "image/png"}}
          end)

        SessionCore.save_avatar(binary, media_type)
        data_uri = "data:#{media_type};base64,#{Base.encode64(binary)}"
        assign(socket, :user_avatar, data_uri)
      else
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  # --- Workspace tab events ---

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

      # Add to open workspaces map if not already there
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
        # Already open — just switch to it
        {:noreply, assign(socket, :active_workspace_id, key)}

      true ->
        case WorkspaceRegistry.get(key) do
          nil ->
            {:noreply, socket}

          ws_mod ->
            shell =
              socket.assigns.shell
              |> Shell.add_workspace(key)
              |> Shell.show_chat()

            socket =
              socket
              |> assign(:workspaces, Map.put(socket.assigns.workspaces, key, ws_mod))
              |> assign(
                :ws_states,
                Map.put(socket.assigns.ws_states, key, ws_mod.projection().init())
              )
              |> assign(:active_workspace_id, key)
              |> assign(:shell, shell)

            socket = maybe_hydrate_workspace(socket, key, ws_mod)

            {:noreply, socket}
        end
    end
  end

  def handle_event("close_workspace", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    if is_atom(key) and Map.has_key?(socket.assigns.workspaces, key) do
      new_workspaces = Map.delete(socket.assigns.workspaces, key)
      new_ws_states = Map.delete(socket.assigns.ws_states, key)

      # If we closed the active tab, switch to next
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

  def handle_event("switch_thread", %{"thread_id" => thread_id}, socket) do
    sid = socket.assigns.session_id
    workspace = File.cwd!()

    # 1. Save current thread's snapshot
    current_thread = Threads.active(sid, workspace)

    if current_thread do
      snapshot = Snapshot.build_snapshot(socket)
      Snapshot.save(sid, workspace, snapshot, thread_id: current_thread["id"])
    end

    # 2. Switch active thread in registry
    case Threads.switch(sid, workspace, thread_id) do
      :ok ->
        target = Threads.get(sid, workspace, thread_id)

        # 3. Stop the current primary agent
        Rho.Agent.Primary.stop(sid)

        # 4. Unsubscribe from current signals
        socket = SessionCore.unsubscribe(socket)

        # 5. Restart agent with new tape
        start_opts = [tape_ref: target["tape_name"]]
        socket = SessionCore.subscribe_and_hydrate(socket, sid, start_opts)

        # 6. Load target thread's snapshot (or start fresh)
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

    # Ensure thread registry exists before forking
    primary_id = Rho.Agent.Primary.agent_id(sid)

    case Rho.Agent.Registry.get(primary_id) do
      %{tape_ref: tape_name} when is_binary(tape_name) ->
        Threads.init(sid, workspace, tape_name: tape_name)

      _ ->
        :ok
    end

    # message_index is a 0-based index into the active agent's message list
    fork_point =
      case Integer.parse(idx_str) do
        {n, _} when n >= 0 -> n
        _ -> nil
      end

    # Save snapshot of current thread before forking
    current_thread = Threads.active(sid, workspace)

    if current_thread do
      snapshot = Snapshot.build_snapshot(socket)
      Snapshot.save(sid, workspace, snapshot, thread_id: current_thread["id"])
    end

    # Capture messages up to fork point before switching
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
        # Restart agent on fork tape
        Rho.Agent.Primary.stop(sid)
        socket = SessionCore.unsubscribe(socket)
        start_opts = [tape_ref: thread["tape_name"]]
        socket = SessionCore.subscribe_and_hydrate(socket, sid, start_opts)

        # Restore forked messages into the new thread's agent
        new_agent_id = socket.assigns.active_agent_id
        agent_messages = Map.put(socket.assigns.agent_messages, new_agent_id, forked_msgs)
        socket = assign(socket, :agent_messages, agent_messages)

        # Persist the forked snapshot so it survives thread switches
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

    # Create a fresh tape for the blank thread
    tape_name = "#{sid}_thread_#{:erlang.unique_integer([:positive])}"
    tape_module.bootstrap(tape_name)

    case Threads.create(sid, workspace, %{"name" => "New Thread", "tape_name" => tape_name}) do
      {:ok, thread} ->
        # Save current snapshot, then switch
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

    # If closing the active thread, switch to Main first
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

  # --- Shell activity pulse decay ---

  @impl true
  def handle_info({:clear_pulse, key}, socket) do
    {:noreply, assign(socket, :shell, Shell.clear_pulse(socket.assigns.shell, key))}
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
          # Delegate to existing handle_event
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

  # --- Workspace state write-back from LiveComponents ---

  def handle_info({:ws_state_update, key, new_state}, socket) do
    {:noreply, SignalRouter.write_ws_state(socket, key, new_state)}
  end

  def handle_info({:lens_detail_request, _} = msg, socket) do
    dispatch_to_workspace(socket, RhoWeb.Workspaces.LensDashboard, msg)
  end

  # --- DataTable snapshot-cache messages (from DataTableComponent / EffectDispatcher) ---

  def handle_info({:data_table_refresh, table_name}, socket) do
    {:noreply, refresh_data_table_active(socket, table_name)}
  end

  def handle_info({:data_table_switch_tab, name}, socket) do
    sid = socket.assigns.session_id

    state =
      DataTableHelpers.ensure_dt_keys(
        SignalRouter.read_ws_state(socket, :data_table) || DataTableHelpers.dt_initial_state()
      )

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

  def handle_info({:data_table_view_change, view_key, mode_label}, socket) do
    state =
      DataTableHelpers.ensure_dt_keys(
        SignalRouter.read_ws_state(socket, :data_table) || DataTableHelpers.dt_initial_state()
      )

    new_state = %{state | view_key: view_key, mode_label: mode_label}
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

  def handle_info({:data_table_error, reason}, socket) do
    state =
      DataTableHelpers.ensure_dt_keys(
        SignalRouter.read_ws_state(socket, :data_table) || DataTableHelpers.dt_initial_state()
      )

    new_state = %{state | error: reason}
    {:noreply, SignalRouter.write_ws_state(socket, :data_table, new_state)}
  end

  def handle_info({:data_table_save, table_name, new_name}, socket) do
    {:noreply, DataTableHelpers.handle_save(socket, table_name, new_name)}
  end

  def handle_info({:data_table_fork, table_name}, socket) do
    {:noreply, DataTableHelpers.handle_fork(socket, table_name)}
  end

  def handle_info({:data_table_publish, table_name, new_name, version_tag}, socket) do
    {:noreply, DataTableHelpers.handle_publish(socket, table_name, new_name, version_tag)}
  end

  def handle_info({:data_table_flash, message}, socket) do
    {:noreply, DataTableHelpers.set_flash(socket, message)}
  end

  # --- Chatroom @mention routing ---

  def handle_info({:chatroom_mention, target, text}, socket) do
    sid = socket.assigns.session_id

    if sid do
      case resolve_mention_target(sid, target) do
        nil -> {:noreply, socket}
        agent_id -> route_mention_to_agent(socket, agent_id, text)
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:chatroom_broadcast, message}, socket) do
    sid = socket.assigns.session_id

    if sid do
      # Send to the primary agent (broadcast appears in chatroom via signal bus)
      SessionCore.send_message(socket, message)
    else
      {:noreply, socket}
    end
  end

  # --- LiveEvents ---

  @impl true
  def handle_info(%LiveEvent{} = event, socket) do
    sid = socket.assigns.session_id

    if sid do
      cond do
        event.kind == :data_table ->
          {:noreply, apply_data_table_event(socket, event.data)}

        event.kind == :workspace_open ->
          {:noreply, apply_open_workspace_event(socket, event.data)}

        true ->
          # Inject correlation_id for SignalRouter shell auto-open logic.
          # LiveEvent data has turn_id (same value — set by Worker.build_emit).
          data = Map.put_new(event.data, :correlation_id, event.data[:turn_id])

          signal = %{kind: event.kind, data: data, emitted_at: event.timestamp}

          socket =
            try do
              SignalRouter.route(socket, signal, WorkspaceRegistry.all())
            rescue
              e ->
                Logger.error(
                  "[session_live] LiveEvent processing crashed: #{Exception.message(e)} " <>
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

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if sid = socket.assigns[:session_id] do
      # Save UI snapshot for resume
      snapshot = Snapshot.build_snapshot(socket)
      Snapshot.save(sid, File.cwd!(), snapshot)
    end

    :ok
  end

  # --- Render ---

  @impl true
  def render(assigns) do
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
        <%!-- Workspace panels — all render continuously, only active is visible --%>
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

        <%!-- Empty state when no workspaces are pinned --%>
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

      <%!-- Workspace overlays — slide-in panels for auto-opened workspaces --%>
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

      <%!-- Command palette --%>
      <.live_component
        module={RhoWeb.CommandPaletteComponent}
        id="command-palette-component"
        open={@command_palette_open}
        workspaces={@workspaces}
        shell={@shell}
        threads={@threads}
      />

      <%!-- Floating chat pill in focus mode --%>
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

  @doc false
  def append_message(socket, msg) do
    RhoWeb.Session.SignalRouter.append_message(socket, msg)
  end

  # Attempt to load a snapshot and apply it, then tail-replay any signals
  # emitted after the snapshot timestamp to catch up.
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

  # Replay EventLog entries emitted after `since_ms` through SignalRouter
  # so workspace projections catch up to current state.
  defp tail_replay(socket, _sid, nil), do: socket

  defp tail_replay(socket, sid, since_ms) when is_integer(since_ms) do
    {events, _last_seq} = Rho.Agent.EventLog.read(sid, limit: 10_000)

    signals_since =
      events
      |> Enum.filter(fn evt ->
        ts_ok =
          case evt["emitted_at"] do
            ts when is_integer(ts) -> ts > since_ms
            _ -> false
          end

        # Only replay events belonging to this session (prevents cross-session agent ghosts)
        session_ok = evt["session_id"] == nil or evt["session_id"] == sid

        ts_ok and session_ok
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

  # EventLog stores data with string keys; convert to atom keys for projections.
  defp deserialize_event_data(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {safe_to_existing_atom(k), v} end)
  end

  defp safe_to_existing_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end

  defp safe_to_existing_atom(other), do: other

  # --- DataTable helpers (delegated to DataTableHelpers) ---

  defp apply_data_table_event(socket, data),
    do: DataTableHelpers.apply_data_table_event(socket, data)

  defp apply_open_workspace_event(socket, data),
    do: DataTableHelpers.apply_open_workspace_event(socket, data)

  defp refresh_data_table_session(socket),
    do: DataTableHelpers.refresh_data_table_session(socket)

  defp refresh_data_table_active(socket, table_name),
    do: DataTableHelpers.refresh_data_table_active(socket, table_name)

  defp determine_workspaces(_live_action), do: %{}

  # Smart chat panel mode from shell state:
  # - :hidden when chatroom is the active workspace (redundant)
  # - Uses shell.chat_mode otherwise
  defp chat_panel_mode(assigns) do
    cond do
      assigns.active_workspace_id == :chatroom -> :hidden
      map_size(assigns.workspaces) == 0 -> :expanded
      true -> assigns.shell.chat_mode
    end
  end

  # Dispatch a handle_info message to a workspace module's handle_info/3 callback.
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

  # Available workspaces that aren't already open as tabs or overlays (for "+" picker)
  defp available_workspaces(assigns) do
    open_keys = Map.keys(assigns.workspaces)
    overlay_keys = Shell.overlay_keys(assigns.shell)
    all_visible = open_keys ++ overlay_keys

    WorkspaceRegistry.all()
    |> Enum.reject(fn mod -> mod.key() in all_visible end)
    |> Map.new(fn mod -> {mod.key(), mod} end)
  end

  # Hydrate a single workspace from tape replay (for dynamically added tabs).
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

  # Merge new workspaces into the socket, initializing any that don't exist yet.
  defp merge_workspaces(socket, new_workspaces) do
    current = socket.assigns.workspaces

    added = Map.drop(new_workspaces, Map.keys(current))

    if map_size(added) == 0 do
      socket
    else
      merged_ws = Map.merge(current, added)

      # Update shell to mark newly added workspaces as open tabs
      shell =
        Enum.reduce(Map.keys(added), socket.assigns.shell, fn key, sh ->
          Shell.add_workspace(sh, key)
        end)

      socket
      |> assign(:workspaces, merged_ws)
      |> assign(:shell, shell)
    end
  end

  # Options for ensure_session/subscribe_and_hydrate based on live_action.
  defp session_ensure_opts(:data_table), do: [agent_name: :data_table, id_prefix: "sheet"]
  defp session_ensure_opts(:chatroom), do: [id_prefix: "chat"]
  defp session_ensure_opts(_), do: []

  # Extract known context params from URL query string for chat handoff.
  # Only whitelisted string keys are extracted — no atom conversion.
  defp extract_chat_context(params) do
    %{}
    |> maybe_put("library_id", params["library_id"])
    |> maybe_put("context", params["context"])
    |> maybe_put("role_profile_name", params["role_profile_name"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value) when is_binary(value), do: Map.put(map, key, value)

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

  defp maybe_hydrate_workspace(socket, key, ws_mod) do
    if socket.assigns.session_id do
      hydrate_workspace(socket, socket.assigns.session_id, key, ws_mod)
    else
      socket
    end
  end

  defp resolve_mention_target(sid, target) do
    case Rho.Agent.Worker.whereis(target) do
      pid when is_pid(pid) ->
        target

      nil ->
        role_atom =
          try do
            String.to_existing_atom(target)
          rescue
            ArgumentError -> nil
          end

        case role_atom && Rho.Agent.Registry.find_by_role(sid, role_atom) do
          [agent | _] -> agent.agent_id
          _ -> nil
        end
    end
  end

  defp route_mention_to_agent(socket, target_agent_id, text) do
    prev_agent_id = socket.assigns.active_agent_id
    socket = assign(socket, :active_agent_id, target_agent_id)

    case SessionCore.send_message(socket, text) do
      {:noreply, socket} ->
        {:noreply, assign(socket, :active_agent_id, prev_agent_id)}
    end
  end

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

  defp read_dt_state(socket) do
    DataTableHelpers.ensure_dt_keys(
      SignalRouter.read_ws_state(socket, :data_table) || DataTableHelpers.dt_initial_state()
    )
  end

  defp update_selection(socket, state, table, %MapSet{} = new_set) do
    sid = socket.assigns[:session_id]
    ids = MapSet.to_list(new_set)

    # Write directly to the server so the agent's `prompt_sections/2` sees
    # the selection on the next turn. The PubSub listener bridge only
    # subscribes between `:agent_started` and `:agent_stopped`, so clicks
    # in the between-turn gap would otherwise be lost.
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
end
