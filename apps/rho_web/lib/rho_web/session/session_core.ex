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

  @avatar_dir Path.expand("~/.rho")

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
    |> assign(:user_avatar, load_avatar("avatar"))
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
    {:ok, _pid} = Rho.Agent.Primary.ensure_started(session_id, opts)

    Rho.Events.subscribe(session_id)

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
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    session_start_opts =
      session_opts(socket)
      |> then(fn o -> if agent_name, do: Keyword.put(o, :agent, agent_name), else: o end)

    if session_id do
      {:ok, _handle} = Rho.Session.start([session_id: session_id] ++ session_start_opts)
      init_threads(session_id, workspace)
      {session_id, socket}
    else
      new_sid = "#{id_prefix}_#{System.unique_integer([:positive])}"
      {:ok, _handle} = Rho.Session.start([session_id: new_sid] ++ session_start_opts)
      init_threads(new_sid, workspace)
      {new_sid, assign(socket, :session_id, new_sid)}
    end
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

  @doc "Load a user or agent avatar from ~/.rho by filename prefix."
  def load_avatar(prefix) do
    path =
      Path.wildcard(Path.join(@avatar_dir, "#{prefix}.*"))
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

  @doc "Load the agent avatar, checking CLI config first."
  def load_agent_avatar do
    load_avatar("agent_avatar")
  end

  @doc "Save a user avatar to ~/.rho."
  def save_avatar(binary, media_type) do
    File.mkdir_p!(@avatar_dir)
    for old <- Path.wildcard(Path.join(@avatar_dir, "avatar.*")), do: File.rm(old)
    ext = media_type_to_ext(media_type)
    File.write!(Path.join(@avatar_dir, "avatar.#{ext}"), binary)
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
