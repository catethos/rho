defmodule RhoWeb.AppLiveChatRailTest do
  use ExUnit.Case, async: true

  alias RhoWeb.AppLive.ChatRail

  test "items/4 builds one row for an unthreaded conversation" do
    conversation = %{
      "id" => "c1",
      "session_id" => "s1",
      "title" => "New conversation",
      "updated_at" => "2026-05-15T10:00:00Z",
      "threads" => []
    }

    [item] =
      ChatRail.items(conversation, "c1", nil, [%{role: :user, content: "  hello   world  "}])

    assert item.id == "c1"
    assert item.conversation_id == "c1"
    assert item.thread_id == nil
    assert item.title == "hello world"
    assert item.preview == "You: hello world"
    assert item.agent_name == :default
    assert item.active
  end

  test "items/4 expands multi-thread conversations and uses thread names for inactive rows" do
    conversation = %{
      "id" => "c1",
      "session_id" => "s1",
      "agent_name" => "researcher",
      "title" => "New conversation",
      "threads" => [
        %{
          "id" => "t1",
          "name" => "Main",
          "summary" => "First thread",
          "updated_at" => "2026-05-15T09:00:00Z"
        },
        %{
          "id" => "t2",
          "name" => "Deep dive",
          "summary" => "Second thread",
          "updated_at" => "2026-05-15T10:00:00Z"
        }
      ]
    }

    [first, second] =
      ChatRail.items(conversation, "c1", "t1", [%{role: :assistant, content: "Active answer"}])

    assert first.id == "c1:t1"
    assert first.thread_id == "t1"
    assert first.title == "New chat"
    assert first.preview == "Assistant: Active answer"
    assert first.active

    assert second.id == "c1:t2"
    assert second.thread_id == "t2"
    assert second.title == "Deep dive"
    assert second.preview == "Second thread"
    refute second.active
    assert second.agent_name == "researcher"
  end

  test "text/1 normalizes mixed content blocks without dynamic assumptions" do
    assert ChatRail.text(%{
             content: [%{text: "one"}, %{"text" => "two"}, "three", %{ignored: true}]
           }) == "one two three"
  end

  test "truncate/2 handles nil and long strings" do
    assert ChatRail.truncate(nil, 5) == ""
    assert ChatRail.truncate("abcdef", 3) == "abc..."
    assert ChatRail.truncate("abc", 3) == "abc"
  end
end
