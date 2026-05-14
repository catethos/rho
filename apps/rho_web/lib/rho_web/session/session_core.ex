defmodule RhoWeb.Session.SessionCore do
  @moduledoc """
  Shared session lifecycle logic used by SessionLive.

  Provides:
  - Session ID validation
  - Signal bus subscription and agent hydration
  - Session creation (ensure_session)
  - Common assigns initialization
  - Message sending
  - Avatar loading
  - UI stream tick handling
  """

  import Phoenix.Component, only: [assign: 3]

  # Where the agent (system-wide) avatar lives. User avatars are
  # per-user under `Rho.Paths.user_avatar_dir/1`.
  defp shared_avatar_dir, do: Rho.Paths.data_dir()

  # -------------------------------------------------------------------
  # Session ID validation
  # -------------------------------------------------------------------

  @doc "Validate and normalize a session_id from params. Returns the ID or nil."
  def validate_session_id(nil), do: nil

  def validate_session_id(sid) do
    case Rho.Agent.Primary.validate_session_id(sid) do
      :ok -> sid
      {:error, _} -> nil
    end
  end

  # -------------------------------------------------------------------
  # Common assigns initialization
  # -------------------------------------------------------------------

  @doc """
  Initialize the common assigns shared by all session LiveViews.

  `opts` may include:
  - `:active_page` — the page identifier (e.g. `:chat`, `:editor`)
  """
  def init(socket, opts \\ []) do
    active_page = Keyword.get(opts, :active_page, :chat)

    socket
    |> assign(:active_page, active_page)
    |> assign(:session_id, nil)
    |> assign(:agents, %{})
    |> assign(:active_agent_id, nil)
    |> assign(:agent_tab_order, [])
    |> assign(:inflight, %{})
    |> assign(:signals, [])
    |> assign(:agent_messages, %{})
    |> assign(:ui_streams, %{})
    |> assign(:total_input_tokens, 0)
    |> assign(:total_output_tokens, 0)
    |> assign(:total_cost, 0.0)
    |> assign(:total_cached_tokens, 0)
    |> assign(:total_reasoning_tokens, 0)
    |> assign(:step_input_tokens, 0)
    |> assign(:step_output_tokens, 0)
    |> assign(:debug_projections, %{})
    |> assign(:next_id, 1)
    |> assign(:connected, Phoenix.LiveView.connected?(socket))
    |> assign(:user_avatar, load_user_avatar(socket))
    |> assign(:agent_avatar, load_agent_avatar())
  end

  # -------------------------------------------------------------------
  # Subscribe & hydrate
  # -------------------------------------------------------------------

  @doc """
  Subscribe to session events and hydrate agent state.

  Ensures the session's primary agent is started, subscribes via
  LiveEvents, hydrates the agent list, and sets up assigns.

  Options are forwarded to `Rho.Agent.Primary.ensure_started/2`.
  """
  def subscribe_and_hydrate(socket, session_id, opts \\ []) do
    user_id = current_user_id(socket)
    opts = Keyword.put_new(opts, :user_id, user_id)
    workspace = Keyword.get(opts, :workspace, user_workspace_for(user_id, session_id))
    {conversation, active_thread} = ensure_conversation(session_id, workspace, opts)

    opts =
      opts
      |> Keyword.put_new(:workspace, workspace)
      |> Keyword.put(:conversation_id, conversation["id"])
      |> Keyword.put(:thread_id, active_thread["id"])
      |> Keyword.put_new(:tape_ref, active_thread["tape_name"])

    tape_module = Rho.Config.tape_module()
    tape_module.bootstrap(opts[:tape_ref])

    case Rho.Agent.Primary.ensure_started(session_id, opts) do
      {:ok, _pid} ->
        :ok = Rho.Events.subscribe(session_id, user_id)
        do_hydrate(socket, session_id)

      {:error, :forbidden} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, "You don't have access to this session.")
        |> Phoenix.LiveView.push_navigate(to: "/")
    end
  end

  defp do_hydrate(socket, session_id) do
    agents =
      Rho.Agent.Registry.list_all(session_id)
      |> Enum.map(fn info ->
        {info.agent_id,
         %{
           agent_id: info.agent_id,
           session_id: info.session_id,
           role: info.role,
           status: info.status,
           depth: info.depth,
           capabilities: info.capabilities,
           model: nil,
           step: nil,
           max_steps: nil
         }}
      end)
      |> Map.new()

    primary_id = primary_agent_id(session_id)
    agent_ids = Map.keys(agents)
    agent_tab_order = [primary_id | agent_ids -- [primary_id]]
    agent_messages = Map.new(agent_ids, fn id -> {id, []} end)

    # Ensure the data table server is running for this session. The
    # server owns row state; tools and the LiveView both read from it.
    Rho.Stdlib.DataTable.ensure_started(session_id)

    schedule_reconciliation()

    socket
    |> assign(:session_id, session_id)
    |> assign(:agents, agents)
    |> assign(:agent_tab_order, agent_tab_order)
    |> assign(:agent_messages, agent_messages)
    |> assign(:active_agent_id, primary_id)
    |> assign(:connected, true)
  end

  # -------------------------------------------------------------------
  # Unsubscribe
  # -------------------------------------------------------------------

  @doc "Unsubscribe from session events."
  def unsubscribe(socket) do
    if sid = socket.assigns[:session_id] do
      Rho.Events.unsubscribe(sid)
    end

    socket
  end

  # -------------------------------------------------------------------
  # Ensure session
  # -------------------------------------------------------------------

  @doc """
  Ensure a session exists, creating one if `session_id` is nil.

  Options:
  - `:agent_name` — the agent config name to use (default: inferred from primary)
  - `:id_prefix` — prefix for generated session IDs (default: `"lv"`)

  Returns `{session_id, socket}`.
  """
  def ensure_session(socket, session_id, opts \\ []) do
    agent_name = Keyword.get(opts, :agent_name)
    id_prefix = Keyword.get(opts, :id_prefix, "lv")
    user_id = current_user_id(socket)

    base_session_opts =
      session_opts(socket)
      |> then(fn o -> if agent_name, do: Keyword.put(o, :agent, agent_name), else: o end)

    sid =
      session_id ||
        "#{id_prefix}_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    workspace = Keyword.get(opts, :workspace, user_workspace_for(user_id, sid))
    {conversation, active_thread} = ensure_conversation(sid, workspace, base_session_opts)

    session_start_opts =
      base_session_opts
      |> Keyword.put(:conversation_id, conversation["id"])
      |> Keyword.put(:thread_id, active_thread["id"])
      |> Keyword.put(:tape_ref, active_thread["tape_name"])

    tape_module = Rho.Config.tape_module()
    tape_module.bootstrap(active_thread["tape_name"])

    {:ok, _handle} =
      Rho.Session.start([session_id: sid, workspace: workspace] ++ session_start_opts)

    init_threads(sid, workspace)

    if session_id do
      {sid, socket}
    else
      {sid, assign(socket, :session_id, sid)}
    end
  end

  # Per-user workspace path (or cwd fallback for anonymous/system code).
  defp user_workspace_for(nil, _sid), do: File.cwd!()
  defp user_workspace_for(user_id, sid), do: Rho.Paths.user_workspace(user_id, sid)

  defp current_user_id(socket) do
    get_in(socket.assigns, [:current_user, Access.key(:id)])
  end

  # -------------------------------------------------------------------
  # Send message
  # -------------------------------------------------------------------

  @doc """
  Send a text message to the active agent (or primary if none selected).

  Returns `{:noreply, socket}` suitable for use in handle_event.
  """
  def send_message(socket, content, opts \\ []) do
    sid = socket.assigns.session_id
    target_id = socket.assigns.active_agent_id
    submit_content = Keyword.get(opts, :submit_content, content)

    user_msg = %{
      id: "user_#{System.unique_integer([:positive])}",
      role: :user,
      type: :text,
      content: content,
      agent_id: target_id
    }

    socket = RhoWeb.Session.SignalRouter.append_message(socket, user_msg)

    result =
      if target_id do
        case Rho.Agent.Worker.whereis(target_id) do
          nil -> {:error, "Agent not found: #{target_id}"}
          pid -> Rho.Agent.Worker.submit(pid, submit_content)
        end
      else
        pid = Rho.Agent.Primary.whereis(sid)
        Rho.Agent.Worker.submit(pid, submit_content)
      end

    case result do
      {:ok, _turn_id} ->
        # Eagerly mark agent as busy so the UI shows the loading indicator
        # immediately, before the turn_started signal arrives from the bus.
        # The agent status is the single source of truth for "pending" state —
        # turn_started confirms :busy, turn_finished sets :idle, and the
        # reconciliation timer self-heals if any signal is lost.
        agent_id = target_id || primary_agent_id(sid)
        agents = socket.assigns.agents

        agents =
          case Map.get(agents, agent_id) do
            nil -> agents
            agent -> Map.put(agents, agent_id, %{agent | status: :busy})
          end

        {:noreply, assign(socket, :agents, agents)}

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, "Failed to send: #{inspect(reason)}")}
    end
  end

  # -------------------------------------------------------------------
  # UI stream tick handling
  # -------------------------------------------------------------------

  @doc "Handle {:ui_spec_tick, message_id} messages. Returns {:noreply, socket}."
  def handle_ui_spec_tick(socket, message_id) do
    ui_streams = socket.assigns.ui_streams

    case Map.get(ui_streams, message_id) do
      %{queue: [spec | rest], agent_id: agent_id} = stream ->
        socket = update_ui_message(socket, agent_id, message_id, spec, true)
        stream = %{stream | queue: rest}

        if rest == [] and stream.final_spec do
          socket = update_ui_message(socket, agent_id, message_id, stream.final_spec, false)
          {:noreply, assign(socket, :ui_streams, Map.delete(ui_streams, message_id))}
        else
          ui_streams = Map.put(ui_streams, message_id, stream)
          Process.send_after(self(), {:ui_spec_tick, message_id}, 40)
          {:noreply, assign(socket, :ui_streams, ui_streams)}
        end

      %{queue: [], final_spec: final, agent_id: agent_id} when not is_nil(final) ->
        socket = update_ui_message(socket, agent_id, message_id, final, false)
        {:noreply, assign(socket, :ui_streams, Map.delete(ui_streams, message_id))}

      _ ->
        {:noreply, socket}
    end
  end

  # -------------------------------------------------------------------
  # Agent reconciliation
  # -------------------------------------------------------------------

  @reconcile_interval 5_000

  @doc """
  Schedule the first reconciliation tick. Call from mount (connected phase).
  """
  def schedule_reconciliation do
    Process.send_after(self(), :reconcile_agents, @reconcile_interval)
  end

  @doc """
  Reconcile the LiveView's agent status with AgentRegistry.

  Handles three cases:
  1. Agent shows :busy in LV but is :idle in registry → update to :idle
  2. Agent has stale inflight data but is idle → flush to thinking message
  3. Agent finished but no response message exists → recover from last_result

  Returns `{:noreply, socket}`.
  """
  def handle_reconciliation(socket) do
    sid = socket.assigns[:session_id]

    if sid do
      registry_agents = Rho.Agent.Registry.list_all(sid)
      registry_status = Map.new(registry_agents, fn info -> {info.agent_id, info} end)

      {agents, socket} =
        Enum.reduce(socket.assigns.agents, {socket.assigns.agents, socket}, fn {id, agent},
                                                                               {agents_acc, sock} ->
          case Map.get(registry_status, id) do
            %{status: :idle} when agent.status == :busy ->
              # Agent finished but we missed turn_finished — correct status
              # and flush any stale inflight data
              updated_agent = %{agent | status: :idle}
              sock = flush_stale_inflight(sock, id)
              sock = maybe_recover_result(sock, id, registry_status)
              {Map.put(agents_acc, id, updated_agent), sock}

            _ ->
              {agents_acc, sock}
          end
        end)

      Process.send_after(self(), :reconcile_agents, @reconcile_interval)
      {:noreply, assign(socket, :agents, agents)}
    else
      Process.send_after(self(), :reconcile_agents, @reconcile_interval)
      {:noreply, socket}
    end
  end

  defp flush_stale_inflight(socket, agent_id) do
    case Map.get(socket.assigns.inflight, agent_id) do
      %{chunks: chunks} when chunks != [] ->
        raw = Enum.join(chunks)

        if String.trim(raw) != "" do
          msg = %{
            id: "reconcile_#{System.unique_integer([:positive])}",
            role: :assistant,
            type: :thinking,
            content: raw,
            agent_id: agent_id
          }

          socket
          |> RhoWeb.Session.SignalRouter.append_message(msg)
          |> assign(:inflight, Map.delete(socket.assigns.inflight, agent_id))
        else
          assign(socket, :inflight, Map.delete(socket.assigns.inflight, agent_id))
        end

      _ ->
        socket
    end
  end

  defp maybe_recover_result(socket, agent_id, registry_status) do
    # If the last message for this agent is from the user (no assistant reply),
    # recover the response from the registry's last_result.
    messages = Map.get(socket.assigns.agent_messages, agent_id, [])
    last_msg = List.last(messages)

    if last_msg && last_msg.role == :user do
      case get_in(registry_status, [agent_id, :last_result]) do
        {:ok, text} when is_binary(text) and text != "" ->
          msg = %{
            id: "recovered_#{System.unique_integer([:positive])}",
            role: :assistant,
            type: :text,
            content: text,
            agent_id: agent_id
          }

          RhoWeb.Session.SignalRouter.append_message(socket, msg)

        _ ->
          socket
      end
    else
      socket
    end
  end

  # -------------------------------------------------------------------
  # Session helpers
  # -------------------------------------------------------------------

  @doc "Derive the primary agent ID for a session."
  def primary_agent_id(nil), do: nil
  def primary_agent_id(session_id), do: Rho.Agent.Primary.agent_id(session_id)

  # -------------------------------------------------------------------
  # Avatar helpers
  # -------------------------------------------------------------------

  @doc """
  Load the current user's avatar from their per-user directory.

  Falls back to the legacy shared `~/.rho/avatar.*` path when no user
  is authenticated (CLI / local dev) so existing single-user setups
  keep working.
  """
  def load_user_avatar(socket) do
    case current_user_id(socket) do
      nil -> load_avatar_from(shared_avatar_dir(), "avatar")
      user_id -> load_avatar_from(Rho.Paths.user_avatar_dir(user_id), "avatar")
    end
  end

  @doc "Load the agent avatar from the shared data dir."
  def load_agent_avatar do
    load_avatar_from(shared_avatar_dir(), "agent_avatar")
  end

  @doc """
  Save the current user's uploaded avatar into their per-user dir.
  """
  def save_user_avatar(socket, binary, media_type) do
    dir =
      case current_user_id(socket) do
        nil -> shared_avatar_dir()
        user_id -> Rho.Paths.user_avatar_dir(user_id)
      end

    save_avatar_to(dir, binary, media_type)
  end

  defp load_avatar_from(dir, prefix) do
    path =
      Path.wildcard(Path.join(dir, "#{prefix}.*"))
      |> Enum.find(&(Path.extname(&1) in ~w(.png .jpg .jpeg .gif .webp)))

    case path do
      nil ->
        nil

      path ->
        binary = File.read!(path)
        ext = Path.extname(path) |> String.trim_leading(".")
        media_type = ext_to_media_type(ext)
        "data:#{media_type};base64,#{Base.encode64(binary)}"
    end
  rescue
    _ -> nil
  end

  defp save_avatar_to(dir, binary, media_type) do
    File.mkdir_p!(dir)
    for old <- Path.wildcard(Path.join(dir, "avatar.*")), do: File.rm(old)
    ext = media_type_to_ext(media_type)
    File.write!(Path.join(dir, "avatar.#{ext}"), binary)
  end

  def media_type_to_ext("image/jpeg"), do: "jpg"
  def media_type_to_ext("image/png"), do: "png"
  def media_type_to_ext("image/gif"), do: "gif"
  def media_type_to_ext("image/webp"), do: "webp"
  def media_type_to_ext(_), do: "png"

  def ext_to_media_type("jpg"), do: "image/jpeg"
  def ext_to_media_type("jpeg"), do: "image/jpeg"
  def ext_to_media_type("png"), do: "image/png"
  def ext_to_media_type("gif"), do: "image/gif"
  def ext_to_media_type("webp"), do: "image/webp"
  def ext_to_media_type(_), do: "image/png"

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp init_threads(session_id, workspace) do
    primary_id = Rho.Agent.Primary.agent_id(session_id)

    case Rho.Agent.Registry.get(primary_id) do
      %{tape_ref: tape_name} when is_binary(tape_name) ->
        RhoWeb.Session.Threads.init(session_id, workspace, tape_name: tape_name)

      _ ->
        :ok
    end
  end

  defp ensure_conversation(session_id, workspace, opts) do
    tape_module = Rho.Config.tape_module()
    default_tape = tape_module.memory_ref(session_id, workspace)

    conversation =
      case Rho.Conversation.get_by_session(session_id) do
        %{"workspace" => ^workspace} = existing ->
          existing

        %{"workspace" => nil} = existing ->
          existing

        _ ->
          case RhoWeb.Session.Threads.import_legacy(session_id, workspace,
                 user_id: opts[:user_id],
                 organization_id: opts[:organization_id],
                 tape_name: default_tape
               ) do
            {:ok, imported} ->
              imported

            {:error, _reason} ->
              {:ok, created} =
                Rho.Conversation.create(%{
                  session_id: session_id,
                  user_id: opts[:user_id],
                  organization_id: opts[:organization_id],
                  workspace: workspace,
                  tape_name: default_tape
                })

              created
          end
      end

    active_thread =
      Rho.Conversation.active_thread(conversation["id"]) ||
        List.first(conversation["threads"] || []) ||
        ensure_main_thread(conversation["id"], default_tape)

    {conversation, active_thread}
  end

  defp ensure_main_thread(conversation_id, tape_name) do
    {:ok, thread} =
      Rho.Conversation.create_thread(conversation_id, %{
        "id" => "thread_main",
        "name" => "Main",
        "tape_name" => tape_name
      })

    :ok = Rho.Conversation.switch_thread(conversation_id, thread["id"])
    thread
  end

  defp session_opts(socket) do
    [
      user_id: get_in(socket.assigns, [:current_user, Access.key(:id)]),
      organization_id: get_in(socket.assigns, [:current_organization, Access.key(:id)])
    ]
  end

  defp update_ui_message(socket, agent_id, msg_id, spec, streaming?) do
    agent_messages = socket.assigns.agent_messages

    case Map.get(agent_messages, agent_id) do
      nil ->
        socket

      msgs ->
        updated_msgs = Enum.map(msgs, &update_msg_spec(&1, msg_id, spec, streaming?))
        assign(socket, :agent_messages, Map.put(agent_messages, agent_id, updated_msgs))
    end
  end

  defp update_msg_spec(%{id: id} = msg, id, spec, streaming?),
    do: %{msg | spec: spec, streaming: streaming?}

  defp update_msg_spec(msg, _id, _spec, _streaming?), do: msg
end
