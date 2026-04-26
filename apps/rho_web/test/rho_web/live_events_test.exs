defmodule Rho.EventsTest do
  use ExUnit.Case, async: true

  alias Rho.Events
  alias Rho.Events.Event

  @session_id "test-session-#{:erlang.unique_integer([:positive])}"
  @agent_id "test-agent-1"

  describe "subscribe/1 + broadcast/2" do
    test "delivers events to subscribers" do
      Events.subscribe(@session_id)

      event = Events.event(:text_delta, @session_id, @agent_id, %{text: "hello"})
      :ok = Events.broadcast(@session_id, event)

      assert_receive %Event{kind: :text_delta, data: %{text: "hello"}}
    end

    test "does not deliver events to other sessions" do
      Events.subscribe(@session_id)

      other = "other-session-#{:erlang.unique_integer([:positive])}"
      event = Events.event(:text_delta, other, @agent_id, %{text: "nope"})
      :ok = Events.broadcast(other, event)

      refute_receive %Event{}, 50
    end

    test "unsubscribe stops delivery" do
      sid = "unsub-test-#{:erlang.unique_integer([:positive])}"
      Events.subscribe(sid)
      Events.unsubscribe(sid)

      event = Events.event(:text_delta, sid, @agent_id, %{text: "gone"})
      :ok = Events.broadcast(sid, event)

      refute_receive %Event{}, 50
    end
  end

  describe "subscribe_lifecycle/0 + broadcast_lifecycle/1" do
    test "delivers lifecycle events globally" do
      Events.subscribe_lifecycle()

      event = Events.event(:agent_stopped, @session_id, @agent_id, %{})
      :ok = Events.broadcast_lifecycle(event)

      assert_receive %Event{kind: :agent_stopped, session_id: @session_id}
    end
  end

  describe "normalize/3" do
    test "converts Runner emit map to Event struct" do
      emit = %{type: :tool_start, name: "bash", args: %{cmd: "ls"}, call_id: "c1", turn_id: "1"}
      event = Events.normalize(emit, @session_id, @agent_id)

      assert %Event{
               kind: :tool_start,
               session_id: @session_id,
               agent_id: @agent_id,
               data: data
             } = event

      assert data.name == "bash"
      assert data.args == %{cmd: "ls"}
      assert data.call_id == "c1"
      assert data.turn_id == "1"
      assert data.session_id == @session_id
      assert data.agent_id == @agent_id
      # :type is stripped from data (it's in :kind)
      refute Map.has_key?(data, :type)
      assert is_integer(event.timestamp)
    end

    test "converts text_delta emit" do
      emit = %{type: :text_delta, text: "hello world", turn_id: "2"}
      event = Events.normalize(emit, @session_id, @agent_id)

      assert event.kind == :text_delta
      assert event.data.text == "hello world"
    end

    test "converts turn_finished emit" do
      emit = %{type: :turn_finished, result: {:ok, "done"}, turn_id: "3"}
      event = Events.normalize(emit, @session_id, @agent_id)

      assert event.kind == :turn_finished
      assert event.data.result == {:ok, "done"}
    end
  end

  describe "event/4" do
    test "builds lifecycle event" do
      event =
        Events.event(:agent_started, @session_id, @agent_id, %{
          role: :primary,
          depth: 0,
          capabilities: [:bash]
        })

      assert event.kind == :agent_started
      assert event.data.role == :primary
      assert event.data.depth == 0
    end

    test "builds event with nil agent_id" do
      event = Events.event(:data_table, @session_id, nil, %{event: :view_change})

      assert event.kind == :data_table
      assert event.agent_id == nil
    end

    test "defaults data to empty map" do
      event = Events.event(:agent_stopped, @session_id, @agent_id)

      assert event.data == %{}
    end
  end

  describe "topic/1" do
    test "returns scoped topic string" do
      assert Events.topic("abc-123") == "rho:session:abc-123"
    end
  end
end
