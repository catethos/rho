defmodule RhoWeb.Projections.ChatroomProjectionTest do
  use ExUnit.Case, async: true

  alias RhoWeb.Projections.ChatroomProjection

  defp signal(kind, data) do
    %{kind: kind, data: data}
  end

  describe "handles?/1" do
    test "matches chatroom event kinds" do
      assert ChatroomProjection.handles?(:message_sent)
      assert ChatroomProjection.handles?(:broadcast)
      assert ChatroomProjection.handles?(:text_delta)
      assert ChatroomProjection.handles?(:llm_text)
      assert ChatroomProjection.handles?(:turn_finished)
    end

    test "rejects non-chatroom event kinds" do
      refute ChatroomProjection.handles?(:tool_start)
      refute ChatroomProjection.handles?(:spreadsheet_rows_delta)
      refute ChatroomProjection.handles?(:llm_usage)
    end
  end

  describe "init/0" do
    test "returns empty initial state" do
      assert ChatroomProjection.init() == %{messages: [], streaming: %{}}
    end
  end

  describe "reduce - message_sent" do
    test "appends outgoing message with speaker" do
      state = ChatroomProjection.init()

      state =
        ChatroomProjection.reduce(
          state,
          signal(:message_sent, %{
            from: "agent_1",
            to: "agent_2",
            message: "Hello there",
            event_id: "evt_1",
            emitted_at: 1_000_000
          })
        )

      assert length(state.messages) == 1
      [msg] = state.messages
      assert msg.id == "evt_1"
      assert msg.speaker == "agent_1"
      assert msg.direction == :outgoing
      assert msg.content == "Hello there"
      assert msg.timestamp == 1_000_000
    end

    test "successive messages accumulate" do
      state = ChatroomProjection.init()

      state =
        state
        |> ChatroomProjection.reduce(signal(:message_sent, %{from: "a1", message: "first"}))
        |> ChatroomProjection.reduce(signal(:message_sent, %{from: "a2", message: "second"}))

      assert length(state.messages) == 2
      assert Enum.at(state.messages, 0).content == "first"
      assert Enum.at(state.messages, 1).content == "second"
    end
  end

  describe "reduce - broadcast" do
    test "appends broadcast message" do
      state = ChatroomProjection.init()

      state =
        ChatroomProjection.reduce(
          state,
          signal(:broadcast, %{
            from: "coordinator",
            message: "All agents: new task",
            event_id: "evt_b1"
          })
        )

      assert length(state.messages) == 1
      [msg] = state.messages
      assert msg.direction == :broadcast
      assert msg.speaker == "coordinator"
      assert msg.content == "All agents: new task"
    end
  end

  describe "reduce - text_delta + turn_finished (streaming)" do
    test "buffers text_delta and flushes on turn_finished" do
      state = ChatroomProjection.init()

      # Stream some deltas
      state =
        state
        |> ChatroomProjection.reduce(signal(:text_delta, %{agent_id: "agent_1", text: "Hello "}))
        |> ChatroomProjection.reduce(signal(:text_delta, %{agent_id: "agent_1", text: "world"}))

      # Should be buffering, no messages yet
      assert state.messages == []
      assert state.streaming["agent_1"] == "Hello world"

      # Finish the turn
      state =
        ChatroomProjection.reduce(
          state,
          signal(:turn_finished, %{agent_id: "agent_1", event_id: "evt_t1"})
        )

      assert length(state.messages) == 1
      [msg] = state.messages
      assert msg.content == "Hello world"
      assert msg.direction == :incoming
      assert msg.speaker == "agent_1"
      assert state.streaming == %{}
    end

    test "llm_text is treated same as text_delta" do
      state = ChatroomProjection.init()

      state =
        state
        |> ChatroomProjection.reduce(signal(:llm_text, %{agent_id: "agent_1", text: "response"}))
        |> ChatroomProjection.reduce(signal(:turn_finished, %{agent_id: "agent_1"}))

      assert length(state.messages) == 1
      assert hd(state.messages).content == "response"
    end

    test "turn_finished with result but no streaming buffer" do
      state = ChatroomProjection.init()

      state =
        ChatroomProjection.reduce(
          state,
          signal(:turn_finished, %{
            agent_id: "agent_1",
            result: {:ok, "Final answer"},
            event_id: "evt_r1"
          })
        )

      assert length(state.messages) == 1
      assert hd(state.messages).content == "Final answer"
    end

    test "turn_finished with no buffer and no result produces no message" do
      state = ChatroomProjection.init()

      state =
        ChatroomProjection.reduce(
          state,
          signal(:turn_finished, %{agent_id: "agent_1"})
        )

      assert state.messages == []
    end

    test "multiple agents stream independently" do
      state = ChatroomProjection.init()

      state =
        state
        |> ChatroomProjection.reduce(signal(:text_delta, %{agent_id: "a1", text: "from a1"}))
        |> ChatroomProjection.reduce(signal(:text_delta, %{agent_id: "a2", text: "from a2"}))

      assert state.streaming["a1"] == "from a1"
      assert state.streaming["a2"] == "from a2"

      # Finish a1, a2 still streaming
      state =
        ChatroomProjection.reduce(
          state,
          signal(:turn_finished, %{agent_id: "a1"})
        )

      assert length(state.messages) == 1
      assert hd(state.messages).speaker == "a1"
      assert Map.has_key?(state.streaming, "a2")
      refute Map.has_key?(state.streaming, "a1")
    end
  end

  describe "flush_streaming/2" do
    test "flushes a specific agent's buffer to a message" do
      state = %{ChatroomProjection.init() | streaming: %{"a1" => "buffered text"}}

      state = ChatroomProjection.flush_streaming(state, "a1")

      assert length(state.messages) == 1
      assert hd(state.messages).content == "buffered text"
      refute Map.has_key?(state.streaming, "a1")
    end

    test "no-op when buffer is empty" do
      state = ChatroomProjection.init()

      state = ChatroomProjection.flush_streaming(state, "a1")

      assert state.messages == []
    end
  end

  describe "replay determinism" do
    test "replaying a signal sequence produces identical state" do
      signals = [
        signal(:message_sent, %{from: "user", message: "hi", event_id: "e1"}),
        signal(:text_delta, %{agent_id: "a1", text: "hello "}),
        signal(:text_delta, %{agent_id: "a1", text: "there"}),
        signal(:turn_finished, %{agent_id: "a1", event_id: "e2"}),
        signal(:broadcast, %{from: "system", message: "update", event_id: "e3"})
      ]

      run = fn ->
        Enum.reduce(signals, ChatroomProjection.init(), &ChatroomProjection.reduce(&2, &1))
      end

      assert run.() == run.()
    end
  end
end
