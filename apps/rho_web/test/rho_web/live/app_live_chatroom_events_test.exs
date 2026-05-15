defmodule RhoWeb.AppLiveChatroomEventsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.AppLive.ChatroomEvents

  defp socket(assigns) do
    base = %{__changed__: %{}, session_id: nil, active_agent_id: nil}
    struct!(Phoenix.LiveView.Socket, assigns: Map.merge(base, assigns))
  end

  describe "resolve_mention_target/2" do
    test "returns :error for unknown non-atom role names" do
      target = "role-that-should-not-exist-#{System.unique_integer([:positive])}"

      assert ChatroomEvents.resolve_mention_target("sid", target) == :error
    end
  end

  describe "handle_info/2" do
    test "ignores mentions and broadcasts before a session exists" do
      socket = socket(%{})

      assert {:noreply, ^socket} =
               ChatroomEvents.handle_info({:chatroom_mention, "default", "hello"}, socket)

      assert {:noreply, ^socket} =
               ChatroomEvents.handle_info({:chatroom_broadcast, "hello"}, socket)
    end
  end
end
