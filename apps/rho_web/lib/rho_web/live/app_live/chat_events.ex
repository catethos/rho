defmodule RhoWeb.AppLive.ChatEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2]
  require Logger

  alias RhoWeb.AppLive
  alias RhoWeb.AppLive.DataTableEvents
  alias RhoWeb.Session.SessionCore
  alias RhoWeb.Session.Snapshot
  alias RhoWeb.Session.Threads
  alias RhoWeb.Session.Welcome
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  def handle_event("open_chat", %{"conversation_id" => conversation_id} = params, socket) do
    thread_id = params |> Map.get("thread_id") |> blank_to_nil()

    with %{} = conversation <- Rho.Conversation.get(conversation_id),
         true <- AppLive.can_access_conversation?(socket, conversation),
         sid when is_binary(sid) <- conversation["session_id"] do
      workspace = conversation["workspace"] || AppLive.workspace_for_session(socket, sid)
      target_thread_id = AppLive.chat_target_thread_id(conversation, thread_id)

      socket =
        cond do
          sid == socket.assigns[:session_id] and is_binary(target_thread_id) ->
            AppLive.switch_to_thread(socket, sid, workspace, target_thread_id)

          sid == socket.assigns[:session_id] ->
            AppLive.refresh_conversations(socket)

          true ->
            maybe_switch_conversation_thread(conversation["id"], target_thread_id)

            socket
            |> AppLive.switch_to_session(sid,
              workspace: workspace,
              agent_name: AppLive.conversation_agent_name(conversation)
            )
            |> AppLive.maybe_restore_chat_thread(sid, workspace, target_thread_id)
            |> AppLive.refresh_threads()
            |> AppLive.refresh_conversations()
            |> AppLive.push_chat_session_patch(sid)
        end
        |> Welcome.render_for_active_agent()
        |> assign(:editing_conversation_id, nil)
        |> AppLive.refresh_conversations()

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
         true <- AppLive.can_access_conversation?(socket, conversation),
         :ok <- archive_chat_row(socket, conversation, thread_id) do
      {:noreply, after_archive_chat(socket, conversation, active?)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("archive_conversation", %{"conversation_id" => conversation_id}, socket) do
    active? = conversation_id == socket.assigns[:active_conversation_id]

    with %{} = conversation <- Rho.Conversation.get(conversation_id),
         true <- AppLive.can_access_conversation?(socket, conversation),
         {:ok, _} <- Rho.Conversation.archive(conversation_id) do
      {:noreply, after_archive_chat(socket, conversation, active?)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("new_conversation", params, socket) do
    agent_name = params |> Map.get("role") |> AppLive.normalize_agent_role()

    socket =
      socket
      |> AppLive.persist_current_thread_snapshot()
      |> SessionCore.unsubscribe()
      |> AppLive.reset_session_runtime_assigns()
      |> assign(:chat_context, %{})
      |> assign(:show_new_chat, false)
      |> assign(:editing_conversation_id, nil)

    ensure_opts =
      socket.assigns.live_action
      |> AppLive.session_ensure_opts()
      |> Keyword.put(:agent_name, agent_name)

    {sid, socket} = SessionCore.ensure_session(socket, nil, ensure_opts)
    {:ok, _pid} = Rho.Stdlib.Uploads.ensure_started(sid)

    socket =
      socket
      |> SessionCore.subscribe_and_hydrate(sid, ensure_opts)
      |> AppLive.rebuild_chat_from_active_thread()
      |> Welcome.maybe_render()
      |> AppLive.refresh_threads()
      |> AppLive.refresh_conversations()
      |> DataTableEvents.refresh_session()
      |> AppLive.push_chat_session_patch(sid)

    {:noreply, socket}
  end

  def handle_event("edit_chat_title", %{"conversation_id" => conversation_id}, socket) do
    with %{} = conversation <- Rho.Conversation.get(conversation_id),
         true <- AppLive.can_access_conversation?(socket, conversation) do
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
         true <- AppLive.can_access_conversation?(socket, conversation),
         {:ok, _conversation} <- Rho.Conversation.set_title(conversation_id, title) do
      {:noreply,
       socket |> assign(:editing_conversation_id, nil) |> AppLive.refresh_conversations()}
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
          %{} = conversation -> AppLive.can_access_conversation?(socket, conversation)
          _ -> false
        end
      end)

    if ids != [] do
      Rho.Conversation.reorder(ids)
    end

    {:noreply, AppLive.refresh_conversations(socket)}
  end

  def handle_event("switch_thread", %{"thread_id" => thread_id}, socket) do
    sid = socket.assigns.session_id
    workspace = AppLive.user_workspace(socket)
    {:noreply, AppLive.switch_to_thread(socket, sid, workspace, thread_id)}
  end

  def handle_event("fork_from_here", %{"entry_id" => entry_id_str}, socket) do
    sid = socket.assigns.session_id
    workspace = AppLive.user_workspace(socket)
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
        socket = AppLive.rebuild_chat_from_thread(socket, thread)
        fork_snapshot = Snapshot.build_snapshot(socket)
        Snapshot.save(sid, workspace, fork_snapshot, thread_id: thread["id"])
        {:noreply, socket |> AppLive.refresh_threads() |> AppLive.refresh_conversations()}

      {:error, reason} ->
        Logger.warning("fork_from_here failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_event("fork_from_here", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("new_blank_thread", _params, socket) do
    sid = socket.assigns.session_id
    workspace = AppLive.user_workspace(socket)
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
         |> AppLive.rebuild_chat_from_thread(thread)
         |> AppLive.refresh_threads()
         |> AppLive.refresh_conversations()}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_thread", %{"thread_id" => thread_id}, socket) do
    sid = socket.assigns.session_id
    workspace = AppLive.user_workspace(socket)
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
          _ -> AppLive.rebuild_chat_from_thread(socket, main)
        end
      else
        socket
      end

    Threads.delete(sid, workspace, thread_id)
    {:noreply, socket |> AppLive.refresh_threads() |> AppLive.refresh_conversations()}
  end

  defp maybe_switch_conversation_thread(_conversation_id, nil), do: :ok

  defp maybe_switch_conversation_thread(conversation_id, thread_id) do
    case Rho.Conversation.switch_thread(conversation_id, thread_id) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp archive_chat_row(socket, conversation, thread_id) when is_binary(thread_id) do
    if length(conversation["threads"] || []) > 1 do
      sid = conversation["session_id"]
      workspace = conversation["workspace"] || AppLive.workspace_for_session(socket, sid)

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
      |> AppLive.clear_active_chat_session()
      |> AppLive.refresh_conversations()
      |> maybe_push_chat_index_patch()
    else
      AppLive.refresh_conversations(socket)
    end
  end

  defp after_archive_chat(socket, _conversation, _active?) do
    AppLive.refresh_conversations(socket)
  end

  defp chat_row_active?(conversation_id, thread_id, active_id, active_thread_id)
       when conversation_id == active_id do
    is_nil(thread_id) or is_nil(active_thread_id) or thread_id == active_thread_id
  end

  defp chat_row_active?(_conversation_id, _thread_id, _active_id, _active_thread_id), do: false

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

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
