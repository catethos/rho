defmodule RhoWeb.AppLiveLiveEventsTest do
  use ExUnit.Case, async: true

  alias Rho.Events.Event
  alias RhoWeb.AppLive.LiveEvents

  describe "deserialize_event_data/1" do
    test "converts existing atom keys and leaves unknown strings alone" do
      data = LiveEvents.deserialize_event_data(%{"turn_id" => "t1", "not_yet_an_atom" => "x"})

      assert data.turn_id == "t1"
      assert data["not_yet_an_atom"] == "x"
    end

    test "passes non-map values through" do
      assert LiveEvents.deserialize_event_data(nil) == nil
    end
  end

  describe "refresh_conversation_event?/1" do
    test "marks conversation-affecting events" do
      for kind <- [:message_sent, :turn_finished, :tool_start, :tool_result, :error] do
        assert LiveEvents.refresh_conversation_event?(kind)
      end

      refute LiveEvents.refresh_conversation_event?(:text_delta)
      refute LiveEvents.refresh_conversation_event?(:data_table)
    end
  end

  describe "handle_info/2" do
    test "ignores live events before a session is attached" do
      socket = struct!(Phoenix.LiveView.Socket, assigns: %{__changed__: %{}, session_id: nil})
      event = %Event{kind: :text_delta, session_id: "sid", data: %{text: "hi"}}

      assert {:noreply, ^socket} = LiveEvents.handle_info(event, socket)
    end
  end
end
