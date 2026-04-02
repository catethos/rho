defmodule Rho.ObservatoryTest do
  @moduledoc """
  Tests for Rho.Observatory GenServer — metrics collection, diagnostics, and signal processing.
  """

  use ExUnit.Case, async: false

  alias Rho.Observatory

  setup do
    session_id = "obs_test_#{System.unique_integer([:positive])}"
    agent_id = "agent_#{System.unique_integer([:positive])}"

    on_exit(fn -> Observatory.reset(session_id) end)

    %{session_id: session_id, agent_id: agent_id}
  end

  describe "session_metrics/1" do
    test "returns empty metrics for unknown session" do
      metrics = Observatory.session_metrics("nonexistent_session")

      assert metrics.session_id == "nonexistent_session"
      assert metrics.agent_count == 0
      assert metrics.total_tokens == 0
      assert metrics.total_tool_calls == 0
      assert metrics.total_errors == 0
    end

    test "accumulates metrics from signals", %{session_id: sid, agent_id: aid} do
      publish_signal("rho.session.#{sid}.events.tool_start", %{
        session_id: sid,
        agent_id: aid,
        name: "bash"
      })

      publish_signal("rho.session.#{sid}.events.tool_result", %{
        session_id: sid,
        agent_id: aid,
        name: "bash",
        status: :ok,
        latency_ms: 150
      })

      publish_signal("rho.session.#{sid}.events.llm_usage", %{
        session_id: sid,
        agent_id: aid,
        usage: %{input_tokens: 100, output_tokens: 50, cached_tokens: 10},
        cost: 0.001
      })

      # Give GenServer time to process
      Process.sleep(50)

      metrics = Observatory.session_metrics(sid)
      assert metrics.total_tool_calls == 1
      assert metrics.total_tokens == 150
      assert metrics.total_errors == 0
    end
  end

  describe "agent_metrics/1" do
    test "returns empty map for unknown agent" do
      assert Observatory.agent_metrics("nonexistent_agent") == %{}
    end

    test "tracks per-agent tool stats", %{session_id: sid, agent_id: aid} do
      for _ <- 1..3 do
        publish_signal("rho.session.#{sid}.events.tool_start", %{
          session_id: sid,
          agent_id: aid,
          name: "bash"
        })

        publish_signal("rho.session.#{sid}.events.tool_result", %{
          session_id: sid,
          agent_id: aid,
          name: "bash",
          status: :ok,
          latency_ms: 100
        })
      end

      Process.sleep(50)

      metrics = Observatory.agent_metrics(aid)
      assert metrics[:tool_call_count] == 3
      assert metrics[:tool_stats]["bash"].count == 3
    end
  end

  describe "signal_flow/1" do
    test "returns empty list for unknown session" do
      assert Observatory.signal_flow("nonexistent") == []
    end

    test "records task delegation flows", %{session_id: sid, agent_id: aid} do
      publish_signal("rho.task.requested", %{
        session_id: sid,
        agent_id: aid,
        target_agent_id: "child_1"
      })

      Process.sleep(50)

      flows = Observatory.signal_flow(sid)
      assert length(flows) == 1
      assert hd(flows).from == aid
      assert hd(flows).type == :delegation
    end
  end

  describe "recent_events/2" do
    test "returns events in order with limit", %{session_id: sid, agent_id: aid} do
      for i <- 1..5 do
        publish_signal("rho.session.#{sid}.events.step_start", %{
          session_id: sid,
          agent_id: aid,
          step: i
        })
      end

      Process.sleep(50)

      events = Observatory.recent_events(sid, 3)
      assert length(events) == 3
    end
  end

  describe "diagnose/1" do
    test "returns no issues for healthy session" do
      result = Observatory.diagnose("empty_session")
      assert result.issues == []
      assert result.summary.total_issues == 0
    end

    test "detects high error rate", %{session_id: sid, agent_id: aid} do
      # Create 10 tool calls with 5 errors (50% error rate > 30% threshold)
      for i <- 1..10 do
        publish_signal("rho.session.#{sid}.events.tool_start", %{
          session_id: sid,
          agent_id: aid,
          name: "failing_tool"
        })

        status = if i <= 5, do: :error, else: :ok

        publish_signal("rho.session.#{sid}.events.tool_result", %{
          session_id: sid,
          agent_id: aid,
          name: "failing_tool",
          status: status,
          latency_ms: 50
        })
      end

      Process.sleep(50)

      result = Observatory.diagnose(sid)
      error_issues = Enum.filter(result.issues, &(&1.issue == "high_error_rate"))
      assert length(error_issues) > 0
    end

    test "detects many steps", %{session_id: sid, agent_id: aid} do
      for _ <- 1..25 do
        publish_signal("rho.session.#{sid}.events.step_start", %{
          session_id: sid,
          agent_id: aid
        })
      end

      Process.sleep(50)

      result = Observatory.diagnose(sid)
      step_issues = Enum.filter(result.issues, &(&1.issue == "many_steps"))
      assert length(step_issues) > 0
    end
  end

  describe "sessions/0" do
    test "lists sessions with activity", %{session_id: sid, agent_id: aid} do
      publish_signal("rho.session.#{sid}.events.step_start", %{
        session_id: sid,
        agent_id: aid
      })

      Process.sleep(50)

      sessions = Observatory.sessions()
      assert Enum.any?(sessions, &(&1.session_id == sid))
    end
  end

  describe "reset/1" do
    test "clears metrics for a session", %{session_id: sid, agent_id: aid} do
      publish_signal("rho.session.#{sid}.events.step_start", %{
        session_id: sid,
        agent_id: aid
      })

      Process.sleep(50)
      assert Observatory.session_metrics(sid).agents != []

      Observatory.reset(sid)
      Process.sleep(20)

      metrics = Observatory.session_metrics(sid)
      assert metrics.agents == []
    end
  end

  # --- Helpers ---

  defp publish_signal(type, data) do
    Rho.Comms.publish(type, data, source: "test")
  end
end
