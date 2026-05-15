defmodule RhoWeb.AppLiveMountTest do
  use ExUnit.Case, async: false

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "rho_app_live_mount_#{System.unique_integer([:positive])}")

    old_data_dir = System.get_env("RHO_DATA_DIR")
    System.put_env("RHO_DATA_DIR", data_dir)

    on_exit(fn ->
      if old_data_dir do
        System.put_env("RHO_DATA_DIR", old_data_dir)
      else
        System.delete_env("RHO_DATA_DIR")
      end

      File.rm_rf!(data_dir)
    end)

    :ok
  end

  test "connected /chat mount does not create a conversation without an explicit action" do
    socket =
      build_socket(%{
        live_action: :chat_new,
        current_user: %{id: 123},
        current_organization: %{id: 456, slug: "acme"}
      })
      |> put_private_connected()

    assert {:ok, socket} = RhoWeb.AppLive.mount(%{}, %{}, socket)

    assert socket.assigns.session_id == nil
    assert Rho.Conversation.list(user_id: 123, organization_id: 456) == []
  end

  test "archive_chat can remove the active final conversation" do
    workspace = Path.join(System.tmp_dir!(), "rho_archive_active_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    {:ok, conversation} =
      Rho.Conversation.create(%{
        session_id: "lv_active_archive",
        user_id: 123,
        organization_id: 456,
        workspace: workspace,
        tape_name: "tape_active_archive"
      })

    socket =
      build_socket(%{
        active_page: :chat,
        live_action: :chat_show,
        current_user: %{id: 123},
        current_organization: %{id: 456, slug: "acme"},
        session_id: "lv_active_archive",
        active_conversation_id: conversation["id"],
        active_thread_id: "thread_main",
        agents: %{},
        active_agent_id: nil,
        agent_tab_order: [],
        agent_messages: %{},
        inflight: %{},
        signals: [],
        ui_streams: %{},
        debug_projections: %{},
        total_input_tokens: 0,
        total_output_tokens: 0,
        total_cost: 0.0,
        total_cached_tokens: 0,
        total_reasoning_tokens: 0,
        step_input_tokens: 0,
        step_output_tokens: 0,
        ws_states: %{},
        threads: [%{"id" => "thread_main", "tape_name" => "tape_active_archive"}],
        selected_agent_id: nil,
        editing_conversation_id: nil,
        show_new_chat: false,
        files_parsing: %{},
        files_pending_send: nil
      })
      |> put_private_connected()

    assert {:noreply, socket} =
             RhoWeb.AppLive.handle_event(
               "archive_chat",
               %{"conversation_id" => conversation["id"], "thread_id" => "thread_main"},
               socket
             )

    assert socket.assigns.session_id == nil
    assert socket.assigns.active_conversation_id == nil
    assert Rho.Conversation.list(user_id: 123, organization_id: 456) == []
    assert [%{"id" => id}] = Rho.Conversation.list(user_id: 123, include_archived: true)
    assert id == conversation["id"]
  end

  defp build_socket(assigns_override) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          flash: %{}
        },
        assigns_override
      )

    struct!(Phoenix.LiveView.Socket, assigns: assigns)
  end

  defp put_private_connected(socket) do
    %{socket | transport_pid: self()}
  end
end
