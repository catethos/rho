defmodule Rho.Session.EventLogTest do
  @moduledoc """
  Tests for Rho.Session.EventLog — JSONL persistence, truncation, and sanitization.
  """

  use ExUnit.Case, async: false

  alias Rho.Session.EventLog

  @tmp_workspace Path.join(System.tmp_dir!(), "rho_eventlog_test")

  setup do
    session_id = "evlog_#{System.unique_integer([:positive])}"
    workspace = Path.join(@tmp_workspace, "#{session_id}")
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)

    {:ok, pid} = EventLog.start_link(session_id: session_id, workspace: workspace)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
      File.rm_rf!(workspace)
    end)

    %{session_id: session_id, workspace: workspace, pid: pid}
  end

  describe "read/2" do
    test "returns empty list for new session", %{session_id: sid} do
      {events, last_seq} = EventLog.read(sid)
      assert events == []
      assert last_seq == 0
    end

    test "returns events after publishing signals", %{session_id: sid} do
      publish_signal("rho.session.#{sid}.events.step_start", %{
        session_id: sid,
        agent_id: "agent_1"
      })

      Process.sleep(50)

      {events, last_seq} = EventLog.read(sid)
      assert length(events) >= 1
      assert last_seq >= 1

      event = hd(events)
      assert event["seq"] >= 1
      assert event["session_id"] == sid
      assert is_binary(event["ts"])
    end

    test "pagination with after option", %{session_id: sid} do
      for i <- 1..5 do
        publish_signal("rho.session.#{sid}.events.step_start", %{
          session_id: sid,
          agent_id: "agent_1",
          step: i
        })
      end

      Process.sleep(50)

      {all_events, _} = EventLog.read(sid, limit: 100)
      assert length(all_events) >= 5

      # Read after the 2nd event
      {page2, _} = EventLog.read(sid, after: 2, limit: 100)
      assert Enum.all?(page2, fn e -> e["seq"] > 2 end)
    end

    test "limit restricts returned events", %{session_id: sid} do
      for i <- 1..5 do
        publish_signal("rho.session.#{sid}.events.step_start", %{
          session_id: sid,
          agent_id: "agent_1",
          step: i
        })
      end

      Process.sleep(50)

      {events, _} = EventLog.read(sid, limit: 2)
      assert length(events) == 2
    end
  end

  describe "filtered types" do
    test "text_delta events are not persisted", %{session_id: sid} do
      publish_signal("rho.session.#{sid}.events.text_delta", %{
        session_id: sid,
        agent_id: "agent_1",
        text: "hello"
      })

      publish_signal("rho.session.#{sid}.events.step_start", %{
        session_id: sid,
        agent_id: "agent_1"
      })

      Process.sleep(50)

      {events, _} = EventLog.read(sid)
      types = Enum.map(events, & &1["type"])
      refute Enum.any?(types, &String.contains?(&1, "text_delta"))
    end
  end

  describe "path/1" do
    test "returns JSONL file path", %{session_id: sid, workspace: workspace} do
      path = EventLog.path(sid)
      assert path =~ "events.jsonl"
      assert path =~ workspace
    end

    test "returns nil for unknown session" do
      assert EventLog.path("nonexistent_session") == nil
    end
  end

  describe "truncate_data (via written events)" do
    test "truncates large output fields", %{session_id: sid} do
      large_output = String.duplicate("x", 5000)

      publish_signal("rho.session.#{sid}.events.tool_result", %{
        session_id: sid,
        agent_id: "agent_1",
        name: "bash",
        output: large_output,
        status: :ok
      })

      Process.sleep(50)

      {events, _} = EventLog.read(sid)
      event = List.last(events)
      output = get_in(event, ["data", "output"])
      assert byte_size(output) < 5000
      assert output =~ "... [truncated]"
    end
  end

  describe "sanitize (via written events)" do
    test "converts structs and special types to JSON-safe values", %{session_id: sid} do
      publish_signal("rho.session.#{sid}.events.tool_start", %{
        session_id: sid,
        agent_id: "agent_1",
        name: "test",
        extra_pid: self()
      })

      Process.sleep(50)

      {events, _} = EventLog.read(sid)
      assert length(events) >= 1

      # PID should be stringified
      event = List.last(events)
      pid_val = get_in(event, ["data", "extra_pid"])
      assert is_binary(pid_val)
      assert pid_val =~ "#PID"
    end
  end

  # --- Helpers ---

  defp publish_signal(type, data) do
    Rho.Comms.publish(type, data, source: "test")
  end
end
