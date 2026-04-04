defmodule RhoWeb.SessionLive do
  @moduledoc """
  Main LiveView — single state owner for the entire session UI.
  Subscribes to the signal bus and projects all events into assigns.
  """
  use Phoenix.LiveView

  import RhoWeb.CoreComponents
  import RhoWeb.ChatComponents
  import RhoWeb.AgentComponents
  import RhoWeb.SignalComponents

  alias RhoWeb.SessionProjection

  @impl true
  def mount(params, _session, socket) do
    session_id = params["session_id"]

    socket =
      socket
      |> assign(:session_id, session_id)
      |> assign(:agents, %{})
      |> assign(:active_tab, nil)
      |> assign(:tab_order, [])
      |> assign(:selected_agent_id, nil)
      |> assign(:timeline_open, false)
      |> assign(:drawer_open, false)
      |> assign(:total_input_tokens, 0)
      |> assign(:total_output_tokens, 0)
      |> assign(:total_cost, 0.0)
      |> assign(:total_cached_tokens, 0)
      |> assign(:total_reasoning_tokens, 0)
      |> assign(:step_input_tokens, 0)
      |> assign(:step_output_tokens, 0)
      |> assign(:inflight, %{})
      |> assign(:signals, [])
      |> assign(:connected, connected?(socket))
      |> assign(:show_new_agent, false)
      |> assign(:uploaded_files, [])
      |> assign(:agent_messages, %{})
      |> assign(:ui_streams, %{})
      |> assign(:pending_response, MapSet.new())
      |> assign(:user_avatar, load_avatar())
      |> assign(:agent_avatar, load_agent_avatar())
      |> assign(:debug_mode, false)
      |> assign(:debug_projections, %{})
      |> allow_upload(:images, accept: ~w(.jpg .jpeg .png .gif .webp), max_entries: 5, max_file_size: 10_000_000)
      |> allow_upload(:avatar, accept: ~w(.jpg .jpeg .png .gif .webp), max_entries: 1, max_file_size: 2_000_000, auto_upload: true)

    socket =
      if connected?(socket) && session_id do
        subscribe_and_hydrate(socket, session_id)
      else
        socket
      end

    {:ok, socket, layout: {RhoWeb.Layouts, :app}}
  end

  @impl true
  def handle_params(%{"session_id" => sid}, _uri, socket) do
    socket =
      if socket.assigns.session_id != sid && connected?(socket) do
        unsubscribe_current(socket)
        socket = assign(socket, :session_id, sid)
        subscribe_and_hydrate(socket, sid)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
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
      sid = socket.assigns.session_id

      {sid, socket} =
        if sid do
          {sid, socket}
        else
          new_sid = "lv_#{System.unique_integer([:positive])}"
          {:ok, _pid} = Rho.Session.ensure_started(new_sid)
          socket = subscribe_and_hydrate(socket, new_sid)
          socket = assign(socket, :session_id, new_sid)
          {new_sid, socket}
        end

      # Build message content: text + images
      submit_content =
        if has_images do
          parts = if has_text, do: [ReqLLM.Message.ContentPart.text(content)], else: []
          parts ++ image_parts
        else
          content
        end

      # Add user message to the active tab's message list
      display_text =
        if has_images do
          img_label = "#{length(image_parts)} image#{if length(image_parts) > 1, do: "s"}"
          if has_text, do: "#{content}\n[#{img_label} attached]", else: "[#{img_label} attached]"
        else
          content
        end

      target_id = socket.assigns.active_tab

      user_msg = %{
        id: "user_#{System.unique_integer([:positive])}",
        role: :user,
        type: :text,
        content: display_text,
        agent_id: target_id
      }

      socket = append_message(socket, user_msg)

      # Submit to the active tab's agent (or primary if none)
      result =
        if target_id do
          case Rho.Agent.Worker.whereis(target_id) do
            nil -> {:error, "Agent not found: #{target_id}"}
            pid -> Rho.Agent.Worker.submit(pid, submit_content)
          end
        else
          Rho.Session.submit(sid, submit_content)
        end

      case result do
        {:ok, _turn_id} ->
          pending_id = target_id || primary_agent_id(sid)
          pending = MapSet.put(socket.assigns.pending_response, pending_id)
          {:noreply, assign(socket, :pending_response, pending)}
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to send: #{inspect(reason)}")}
      end
    end
  end

  # --- Tab selection ---

  def handle_event("select_tab", %{"agent-id" => agent_id}, socket) do
    {:noreply, assign(socket, :active_tab, agent_id)}
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

  def handle_event("create_agent", %{"role" => role}, socket) do
    # Auto-create session if none exists
    {sid, socket} =
      case socket.assigns.session_id do
        nil ->
          new_sid = "lv_#{System.unique_integer([:positive])}"
          {:ok, _pid} = Rho.Session.ensure_started(new_sid)
          socket = subscribe_and_hydrate(socket, new_sid)
          socket = assign(socket, :session_id, new_sid)
          {new_sid, socket}

        sid ->
          {sid, socket}
      end

    agent_id = Rho.Session.new_agent_id()
    role_atom = String.to_atom(role)

    # Give each UI-created agent its own tape so conversations are independent
    memory_mod = Rho.Config.memory_module()
    agent_ref = memory_mod.memory_ref(agent_id, File.cwd!())
    memory_mod.bootstrap(agent_ref)

    {:ok, _pid} =
      Rho.Agent.Supervisor.start_worker(
        agent_id: agent_id,
        session_id: sid,
        workspace: File.cwd!(),
        agent_name: role_atom,
        role: role_atom,
        depth: 0,
        memory_ref: agent_ref
      )

    socket =
      socket
      |> assign(:show_new_agent, false)
      |> assign(:active_tab, agent_id)

    {:noreply, socket}
  end

  def handle_event("validate_upload", _params, socket) do
    # Auto-consume avatar uploads when they arrive
    socket =
      if socket.assigns.uploads.avatar.entries != [] do
        entries = socket.assigns.uploads.avatar.entries
        entry = List.first(entries)

        if entry && entry.done? do
          [{binary, media_type}] =
            consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
              {:ok, {File.read!(path), entry.client_type || "image/png"}}
            end)

          save_avatar(binary, media_type)
          data_uri = "data:#{media_type};base64,#{Base.encode64(binary)}"
          assign(socket, :user_avatar, data_uri)
        else
          socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
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

  def handle_event("stop_session", _params, socket) do
    if socket.assigns.session_id do
      Rho.Session.stop(socket.assigns.session_id)
    end

    {:noreply, socket}
  end

  # --- Signal bus events ---

  @impl true
  def handle_info({:signal, %Jido.Signal{type: type, data: data} = signal}, socket) do
    # Filter: only process signals for our session
    sid = socket.assigns.session_id

    if signal_for_session?(data, sid) do
      correlation_id = get_in(signal.extensions || %{}, ["correlation_id"])
      data = Map.put(data, :correlation_id, correlation_id)
      # Normalize session-scoped type: "rho.agent.#{sid}.started" -> "rho.agent.started"
      normalized_type = String.replace(type, ".#{sid}.", ".")
      {:noreply, SessionProjection.project(socket, %{type: normalized_type, data: data})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:ui_spec_tick, message_id}, socket) do
    ui_streams = socket.assigns.ui_streams

    case Map.get(ui_streams, message_id) do
      %{queue: [spec | rest]} = stream ->
        socket = update_ui_message(socket, message_id, spec, true)
        stream = %{stream | queue: rest}

        if rest == [] and stream.final_spec do
          # Queue drained and final spec ready — finalize
          socket = update_ui_message(socket, message_id, stream.final_spec, false)
          {:noreply, assign(socket, :ui_streams, Map.delete(ui_streams, message_id))}
        else
          ui_streams = Map.put(ui_streams, message_id, stream)
          Process.send_after(self(), {:ui_spec_tick, message_id}, 40)
          {:noreply, assign(socket, :ui_streams, ui_streams)}
        end

      %{queue: [], final_spec: final} when not is_nil(final) ->
        socket = update_ui_message(socket, message_id, final, false)
        {:noreply, assign(socket, :ui_streams, Map.delete(ui_streams, message_id))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    active_tab = assigns.active_tab
    active_messages = Map.get(assigns.agent_messages, active_tab, [])
    active_agent = if active_tab, do: Map.get(assigns.agents, active_tab)

    # Filter inflight to only show streaming for the active tab
    active_inflight =
      if active_tab do
        Map.take(assigns.inflight, [active_tab])
      else
        # No tab selected — show primary agent's inflight
        primary_id = primary_agent_id(assigns.session_id)
        Map.take(assigns.inflight, [primary_id])
      end

    assigns =
      assigns
      |> assign(:active_messages, active_messages)
      |> assign(:active_agent, active_agent)
      |> assign(:active_inflight, active_inflight)

    ~H"""
    <div class={"session-layout #{if @drawer_open, do: "drawer-pinned", else: ""} #{if @debug_mode, do: "debug-mode", else: ""}"}>
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

      <div class="main-panels">
        <div class="chat-panel">
          <.tab_bar
            tab_order={@tab_order}
            agents={@agents}
            active_tab={@active_tab}
            inflight={@inflight}
          />
          <.chat_feed
            messages={@active_messages}
            session_id={@session_id || ""}
            inflight={@active_inflight}
            active_tab={@active_tab || ""}
            user_avatar={@user_avatar}
            agent_avatar={@agent_avatar}
            pending={MapSet.member?(@pending_response, @active_tab || primary_agent_id(@session_id))}
          />
          <.chat_input_with_upload
            session_id={@session_id || ""}
            disabled={is_nil(@session_id) && !is_connected?(assigns)}
            uploads={@uploads}
            active_agent={@active_agent}
          />
        </div>

        <.agent_sidebar agents={@agents} selected_agent_id={@selected_agent_id} />

        <.debug_panel
          :if={@debug_mode}
          projections={@debug_projections}
          active_tab={@active_tab}
          session_id={@session_id}
        />
      </div>

      <.new_agent_dialog :if={@show_new_agent} />

      <.signal_timeline open={@timeline_open} />

      <.live_component
        module={RhoWeb.AgentDrawerComponent}
        id="agent-drawer"
        open={@drawer_open}
        agent={@agents[@selected_agent_id]}
        session_id={@session_id || ""}
      />

      <div :if={!@connected} class="reconnect-banner">
        Reconnecting...
      </div>
    </div>
    """
  end

  # --- Header component ---

  attr :session_id, :string, default: nil
  attr :agents, :map, required: true
  attr :total_input_tokens, :integer, required: true
  attr :total_output_tokens, :integer, required: true
  attr :total_cost, :float, required: true
  attr :total_cached_tokens, :integer, required: true
  attr :total_reasoning_tokens, :integer, required: true
  attr :step_input_tokens, :integer, required: true
  attr :step_output_tokens, :integer, required: true
  attr :user_avatar, :string, default: nil
  attr :uploads, :any, required: true
  attr :debug_mode, :boolean, default: false

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

  attr :tab_order, :list, required: true
  attr :agents, :map, required: true
  attr :active_tab, :string, default: nil
  attr :inflight, :map, required: true

  defp tab_bar(assigns) do
    ~H"""
    <div class="chat-tab-bar" :if={length(@tab_order) > 0}>
      <button
        :for={agent_id <- @tab_order}
        class={"chat-tab #{if @active_tab == agent_id, do: "active", else: ""} #{if agent_stopped?(@agents, agent_id), do: "stopped", else: ""}"}
        phx-click="select_tab"
        phx-value-agent-id={agent_id}
      >
        <.status_dot :if={@agents[agent_id]} status={@agents[agent_id].status} />
        <span class="tab-label"><%= tab_label(@agents, agent_id) %></span>
        <span :if={Map.has_key?(@inflight, agent_id)} class="tab-typing">...</span>
      </button>
    </div>
    """
  end

  # --- Chat input with image upload ---

  attr :session_id, :string, required: true
  attr :disabled, :boolean, default: false
  attr :uploads, :any, required: true
  attr :active_agent, :map, default: nil

  defp chat_input_with_upload(assigns) do
    ~H"""
    <div class="chat-input-area">
      <div :if={@uploads.images.entries != []} class="upload-previews">
        <div :for={entry <- @uploads.images.entries} class="upload-preview">
          <.live_img_preview entry={entry} width="60" height="60" />
          <button type="button" class="upload-remove" phx-click="cancel_upload" phx-value-ref={entry.ref}>&times;</button>
          <div :if={entry.progress > 0 and entry.progress < 100} class="upload-progress">
            <%= entry.progress %>%
          </div>
        </div>
      </div>
      <form id="chat-input-form" phx-submit="send_message" phx-change="validate_upload" class="chat-input-form">
        <label class="btn-attach" title="Attach images">
          <.live_file_input upload={@uploads.images} class="sr-only" />
          &#128247;
        </label>
        <textarea
          name="content"
          id="chat-input"
          placeholder={"Message #{if @active_agent, do: @active_agent.role, else: "agent"}..."}
          rows="1"
          disabled={@disabled}
          phx-hook="AutoResize"
        ></textarea>
        <button type="submit" class="btn-send" disabled={@disabled}>Send</button>
      </form>
    </div>
    """
  end

  # --- New agent dialog ---

  defp new_agent_dialog(assigns) do
    roles = Rho.Config.agent_names()
    assigns = assign(assigns, :roles, roles)

    ~H"""
    <div class="modal-overlay" phx-click="toggle_new_agent">
      <div class="modal-dialog" phx-click-away="toggle_new_agent">
        <h3>Create New Agent</h3>
        <div class="agent-role-list">
          <button
            :for={role <- @roles}
            class="agent-role-btn"
            phx-click="create_agent"
            phx-value-role={role}
          >
            <%= role %>
          </button>
        </div>
        <button class="modal-cancel" phx-click="toggle_new_agent">Cancel</button>
      </div>
    </div>
    """
  end

  # --- Debug panel ---

  attr :projections, :map, required: true
  attr :active_tab, :string, default: nil
  attr :session_id, :string, default: nil

  defp debug_panel(assigns) do
    active_tab = assigns.active_tab || primary_agent_id(assigns.session_id)
    projection = Map.get(assigns.projections, active_tab)

    assigns =
      assigns
      |> assign(:projection, projection)
      |> assign(:active_agent_id, active_tab)

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

  defp is_connected?(assigns) when is_map(assigns), do: Map.get(assigns, :connected, false)

  # --- Private helpers ---

  defp subscribe_and_hydrate(socket, session_id) do
    # Ensure session exists
    {:ok, _pid} = Rho.Session.ensure_started(session_id)

    # Subscribe to signal bus only (NOT Rho.Session.subscribe to avoid duplicates)
    {:ok, sub1} = Rho.Comms.subscribe("rho.session.#{session_id}.events.*")
    {:ok, sub2} = Rho.Comms.subscribe("rho.agent.#{session_id}.*")
    {:ok, sub3} = Rho.Comms.subscribe("rho.task.#{session_id}.*")

    # Hydrate agent list
    agents =
      Rho.Agent.Registry.list(session_id)
      |> Enum.map(fn info ->
        {info.agent_id, %{
          agent_id: info.agent_id,
          session_id: info.session_id,
          role: info.role,
          status: info.status,
          depth: info.depth,
          parent_id: info.parent_agent_id,
          capabilities: info.capabilities,
          model: nil,
          step: nil,
          max_steps: nil
        }}
      end)
      |> Map.new()

    primary_id = primary_agent_id(session_id)
    agent_ids = Map.keys(agents)
    tab_order = [primary_id | (agent_ids -- [primary_id])]
    agent_messages = Map.new(agent_ids, fn id -> {id, []} end)

    socket
    |> assign(:session_id, session_id)
    |> assign(:agents, agents)
    |> assign(:tab_order, tab_order)
    |> assign(:agent_messages, agent_messages)
    |> assign(:active_tab, primary_id)
    |> assign(:connected, true)
    |> assign(:bus_subs, [sub1, sub2, sub3])
  end

  defp unsubscribe_current(socket) do
    for sub <- socket.assigns[:bus_subs] || [] do
      Rho.Comms.unsubscribe(sub)
    end

    socket
  end

  defp signal_for_session?(data, session_id) do
    data_sid = data[:session_id] || data["session_id"]
    is_nil(data_sid) or data_sid == session_id
  end

  defp truncate_id(id) when byte_size(id) > 16, do: String.slice(id, 0, 16) <> "..."
  defp truncate_id(id), do: id

  @avatar_dir Path.expand("~/.rho")

  defp load_avatar do
    case find_avatar_file() do
      nil -> nil
      path ->
        binary = File.read!(path)
        ext = Path.extname(path) |> String.trim_leading(".")
        media_type = ext_to_media_type(ext)
        "data:#{media_type};base64,#{Base.encode64(binary)}"
    end
  rescue
    _ -> nil
  end

  defp save_avatar(binary, media_type) do
    File.mkdir_p!(@avatar_dir)
    # Remove any existing avatar files
    for old <- Path.wildcard(Path.join(@avatar_dir, "avatar.*")), do: File.rm(old)
    ext = media_type_to_ext(media_type)
    File.write!(Path.join(@avatar_dir, "avatar.#{ext}"), binary)
  end

  defp find_avatar_file do
    Path.wildcard(Path.join(@avatar_dir, "avatar.*"))
    |> Enum.find(& Path.extname(&1) in ~w(.png .jpg .jpeg .gif .webp))
  end

  defp load_agent_avatar do
    path =
      Path.wildcard(Path.join(@avatar_dir, "agent_avatar.*"))
      |> Enum.find(& Path.extname(&1) in ~w(.png .jpg .jpeg .gif .webp))

    case path do
      nil -> nil
      path ->
        binary = File.read!(path)
        ext = Path.extname(path) |> String.trim_leading(".")
        media_type = ext_to_media_type(ext)
        "data:#{media_type};base64,#{Base.encode64(binary)}"
    end
  rescue
    _ -> nil
  end

  defp media_type_to_ext("image/jpeg"), do: "jpg"
  defp media_type_to_ext("image/png"), do: "png"
  defp media_type_to_ext("image/gif"), do: "gif"
  defp media_type_to_ext("image/webp"), do: "webp"
  defp media_type_to_ext(_), do: "png"

  defp ext_to_media_type("jpg"), do: "image/jpeg"
  defp ext_to_media_type("jpeg"), do: "image/jpeg"
  defp ext_to_media_type("png"), do: "image/png"
  defp ext_to_media_type("gif"), do: "image/gif"
  defp ext_to_media_type("webp"), do: "image/webp"
  defp ext_to_media_type(_), do: "image/png"

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"

  defp primary_agent_id(nil), do: nil
  defp primary_agent_id(session_id), do: "primary_#{session_id}"

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
    agent_id = msg[:agent_id] || primary_agent_id(socket.assigns.session_id)
    agent_messages = socket.assigns.agent_messages
    current = Map.get(agent_messages, agent_id, [])
    updated = Map.put(agent_messages, agent_id, current ++ [msg])
    assign(socket, :agent_messages, updated)
  end

  defp update_ui_message(socket, msg_id, spec, streaming?) do
    agent_messages = socket.assigns.agent_messages

    updated =
      Map.new(agent_messages, fn {agent_id, msgs} ->
        {agent_id, Enum.map(msgs, fn msg ->
          if msg.id == msg_id do
            %{msg | spec: spec, streaming: streaming?}
          else
            msg
          end
        end)}
      end)

    assign(socket, :agent_messages, updated)
  end
end
