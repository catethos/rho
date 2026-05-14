defmodule Rho.Conversation.IndexTest do
  use ExUnit.Case

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "rho_conversation_index_test_#{System.unique_integer([:positive])}"
      )

    old = System.get_env("RHO_DATA_DIR")
    System.put_env("RHO_DATA_DIR", tmp)

    on_exit(fn ->
      if old, do: System.put_env("RHO_DATA_DIR", old), else: System.delete_env("RHO_DATA_DIR")
      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "atomic writes survive reload" do
    index = %{"conversations" => [%{"id" => "conv_a", "session_id" => "sid_a"}]}

    assert :ok = Rho.Conversation.Index.write_index(index)
    assert Rho.Conversation.Index.load_index() == index
    refute File.exists?(Rho.Conversation.Index.index_path() <> ".tmp")
  end

  test "writes conversation file and upserts index entry" do
    conversation = %{
      "id" => "conv_b",
      "session_id" => "sid_b",
      "title" => "Debug",
      "active_thread_id" => "thread_main",
      "created_at" => "2026-05-14T00:00:00Z",
      "updated_at" => "2026-05-14T00:00:00Z",
      "archived_at" => nil,
      "threads" => []
    }

    assert :ok = Rho.Conversation.Index.write_conversation(conversation)
    assert {:ok, loaded} = Rho.Conversation.Index.read_conversation("conv_b")
    assert loaded["session_id"] == "sid_b"
    assert loaded["agent_name"] == "default"
    assert Map.has_key?(loaded, "position")
    assert [%{"id" => "conv_b"}] = Rho.Conversation.Index.index_entries()
  end

  test "upserts preserve explicit conversation order" do
    first = %{
      "id" => "conv_first",
      "session_id" => "sid_first",
      "title" => "First",
      "position" => 1000,
      "active_thread_id" => "thread_main",
      "created_at" => "2026-05-14T00:00:00Z",
      "updated_at" => "2026-05-14T00:00:00Z",
      "archived_at" => nil,
      "threads" => []
    }

    second = %{
      first
      | "id" => "conv_second",
        "session_id" => "sid_second",
        "title" => "Second",
        "position" => 0,
        "updated_at" => "2026-05-14T00:10:00Z"
    }

    assert :ok = Rho.Conversation.Index.write_conversation(first)
    assert :ok = Rho.Conversation.Index.write_conversation(second)

    assert Enum.map(Rho.Conversation.Index.index_entries(), & &1["id"]) == [
             "conv_second",
             "conv_first"
           ]

    assert :ok =
             Rho.Conversation.Index.write_conversation(%{
               first
               | "title" => "First renamed",
                 "updated_at" => "2026-05-14T00:20:00Z"
             })

    assert Enum.map(Rho.Conversation.Index.index_entries(), & &1["id"]) == [
             "conv_second",
             "conv_first"
           ]
  end
end
