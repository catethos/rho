defmodule Rho.ConversationTest do
  use ExUnit.Case

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "rho_conversation_test_#{System.unique_integer([:positive])}")

    old = System.get_env("RHO_DATA_DIR")
    System.put_env("RHO_DATA_DIR", tmp)

    on_exit(fn ->
      if old, do: System.put_env("RHO_DATA_DIR", old), else: System.delete_env("RHO_DATA_DIR")
      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "creates, gets, lists, archives, and touches conversations" do
    {:ok, conversation} =
      Rho.Conversation.create(%{
        session_id: "sid_1",
        user_id: 123,
        organization_id: 456,
        title: "Trace me",
        tape_name: "tape_main"
      })

    assert String.starts_with?(conversation["id"], "conv_")
    assert conversation["session_id"] == "sid_1"
    assert conversation["user_id"] == "123"
    assert conversation["organization_id"] == "456"
    assert conversation["active_thread_id"] == "thread_main"
    assert [%{"tape_name" => "tape_main"}] = conversation["threads"]

    assert Rho.Conversation.get(conversation["id"])["title"] == "Trace me"
    assert Rho.Conversation.get_by_session("sid_1")["id"] == conversation["id"]
    assert [%{"id" => id}] = Rho.Conversation.list(user_id: 123)
    assert id == conversation["id"]
    assert [%{"id" => ^id}] = Rho.Conversation.list(organization_id: 456)

    {:ok, archived} = Rho.Conversation.archive(conversation["id"])
    assert is_binary(archived["archived_at"])
    assert Rho.Conversation.list(user_id: 123) == []
    assert [%{"id" => ^id}] = Rho.Conversation.list(user_id: 123, include_archived: true)
  end

  test "manages threads and prevents deleting the active thread" do
    {:ok, conversation} = Rho.Conversation.create(session_id: "sid_2", tape_name: "main_tape")

    {:ok, thread} =
      Rho.Conversation.create_thread(conversation["id"], %{
        "name" => "Try smaller",
        "tape_name" => "fork_tape",
        "forked_from" => "thread_main",
        "fork_point_entry_id" => 42
      })

    assert thread["name"] == "Try smaller"
    assert length(Rho.Conversation.list_threads(conversation["id"])) == 2

    assert Rho.Conversation.get_thread(conversation["id"], thread["id"])["tape_name"] ==
             "fork_tape"

    assert :ok = Rho.Conversation.switch_thread(conversation["id"], thread["id"])
    assert Rho.Conversation.active_thread(conversation["id"])["id"] == thread["id"]

    assert {:error, :active_thread} =
             Rho.Conversation.delete_thread(conversation["id"], thread["id"])

    assert :ok = Rho.Conversation.switch_thread(conversation["id"], "thread_main")
    assert :ok = Rho.Conversation.delete_thread(conversation["id"], thread["id"])
    assert Rho.Conversation.get_thread(conversation["id"], thread["id"]) == nil
  end
end
