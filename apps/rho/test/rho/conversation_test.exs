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
        agent_name: :researcher,
        title: "Trace me",
        tape_name: "tape_main"
      })

    assert String.starts_with?(conversation["id"], "conv_")
    assert conversation["session_id"] == "sid_1"
    assert conversation["user_id"] == "123"
    assert conversation["organization_id"] == "456"
    assert conversation["agent_name"] == "researcher"
    assert conversation["position"] == 0
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

  test "updates the conversation agent name" do
    {:ok, conversation} =
      Rho.Conversation.create(%{
        session_id: "sid_agent",
        agent_name: :default,
        tape_name: "tape_main"
      })

    {:ok, updated} = Rho.Conversation.set_agent_name(conversation["id"], :spreadsheet)

    assert updated["agent_name"] == "spreadsheet"
    assert Rho.Conversation.get(conversation["id"])["agent_name"] == "spreadsheet"
    assert [entry] = Rho.Conversation.Index.index_entries()
    assert entry["agent_name"] == "spreadsheet"
  end

  test "renames and reorders conversations without touching recency order" do
    {:ok, first} =
      Rho.Conversation.create(%{
        session_id: "sid_first",
        user_id: 123,
        organization_id: 456,
        title: "First",
        tape_name: "first_tape"
      })

    {:ok, second} =
      Rho.Conversation.create(%{
        session_id: "sid_second",
        user_id: 123,
        organization_id: 456,
        title: "Second",
        tape_name: "second_tape"
      })

    assert Enum.map(Rho.Conversation.list(user_id: 123), & &1["id"]) == [
             second["id"],
             first["id"]
           ]

    assert :ok = Rho.Conversation.reorder([first["id"], second["id"]])

    assert Enum.map(Rho.Conversation.list(user_id: 123), & &1["id"]) == [
             first["id"],
             second["id"]
           ]

    {:ok, renamed} = Rho.Conversation.set_title(second["id"], "  Budget model  ")
    assert renamed["title"] == "Budget model"

    {:ok, _touched} = Rho.Conversation.touch(second["id"])

    assert Enum.map(Rho.Conversation.list(user_id: 123), & &1["id"]) == [
             first["id"],
             second["id"]
           ]
  end

  test "lists conversations only inside the requested user and organization scope" do
    {:ok, own} =
      Rho.Conversation.create(%{
        session_id: "sid_own",
        user_id: 123,
        organization_id: 456,
        title: "Own org chat",
        tape_name: "own_tape"
      })

    {:ok, other_org} =
      Rho.Conversation.create(%{
        session_id: "sid_other_org",
        user_id: 123,
        organization_id: 789,
        title: "Other org chat",
        tape_name: "other_org_tape"
      })

    {:ok, other_user} =
      Rho.Conversation.create(%{
        session_id: "sid_other_user",
        user_id: 999,
        organization_id: 456,
        title: "Other user chat",
        tape_name: "other_user_tape"
      })

    assert [%{"id" => own_id}] = Rho.Conversation.list(user_id: 123, organization_id: 456)
    assert own_id == own["id"]

    assert [%{"id" => other_org_id}] = Rho.Conversation.list(user_id: 123, organization_id: 789)
    assert other_org_id == other_org["id"]

    assert [%{"id" => other_user_id}] = Rho.Conversation.list(user_id: 999, organization_id: 456)
    assert other_user_id == other_user["id"]
  end

  test "gets a session conversation inside the requested scope" do
    {:ok, first} =
      Rho.Conversation.create(%{
        session_id: "sid_shared",
        user_id: 123,
        organization_id: 456,
        workspace: "/tmp/rho-user-123/sid_shared",
        title: "First scoped chat",
        tape_name: "first_scoped_tape"
      })

    {:ok, second} =
      Rho.Conversation.create(%{
        session_id: "sid_shared",
        user_id: 123,
        organization_id: 789,
        workspace: "/tmp/rho-user-123-other-org/sid_shared",
        title: "Second scoped chat",
        tape_name: "second_scoped_tape"
      })

    assert Rho.Conversation.get_by_session("sid_shared",
             user_id: 123,
             organization_id: 456,
             workspace: "/tmp/rho-user-123/sid_shared"
           )["id"] == first["id"]

    assert Rho.Conversation.get_by_session("sid_shared",
             user_id: 123,
             organization_id: 789,
             workspace: "/tmp/rho-user-123-other-org/sid_shared"
           )["id"] == second["id"]

    assert Rho.Conversation.get_by_session("sid_shared",
             user_id: 999,
             organization_id: 456,
             workspace: "/tmp/rho-user-999/sid_shared"
           ) == nil
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
