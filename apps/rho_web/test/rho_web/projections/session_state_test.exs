defmodule RhoWeb.Projections.SessionStateTest do
  use ExUnit.Case, async: true

  alias RhoWeb.Projections.SessionState

  defp state(opts \\ []) do
    sid = Keyword.get(opts, :session_id, "test-session")
    SessionState.init(sid)
  end

  defp signal(kind, data, opts \\ %{}) do
    %{kind: kind, data: data, emitted_at: opts[:emitted_at]}
  end

  defp reduce(state, kind, data, opts \\ %{}) do
    SessionState.reduce(state, signal(kind, data, opts))
  end

  describe "init/1" do
    test "returns initial state with correct session_id" do
      s = state(session_id: "abc")
      assert s.session_id == "abc"
      assert s.agents == %{}
      assert s.agent_messages == %{}
      assert s.next_id == 1
      assert s.total_cost == 0.0
    end
  end

  describe "purity — same input produces same output" do
    test "text_delta is deterministic" do
      s = state()
      data = %{agent_id: "agent-1", text: "hello"}

      {s1, e1} = reduce(s, :text_delta, data)
      {s2, e2} = reduce(s, :text_delta, data)

      assert s1 == s2
      assert e1 == e2
    end

    test "agent_started is deterministic" do
      s = state()
      data = %{agent_id: "a1", session_id: "test-session", role: :analyst}

      {s1, _} = reduce(s, :agent_started, data)
      {s2, _} = reduce(s, :agent_started, data)

      assert s1 == s2
    end

    test "turn_finished is deterministic" do
      s = state()
      s = Map.put(s, :agents, %{"a1" => %{agent_id: "a1", status: :busy, step: 1, max_steps: 5}})
      data = %{agent_id: "a1", result: {:ok, "done"}}

      {s1, e1} = reduce(s, :turn_finished, data)
      {s2, e2} = reduce(s, :turn_finished, data)

      assert s1 == s2
      assert e1 == e2
    end

    test "full replay produces identical state" do
      signals = [
        signal(:agent_started, %{agent_id: "a1", session_id: "s", role: :coder}),
        signal(:turn_started, %{agent_id: "a1"}),
        signal(:text_delta, %{agent_id: "a1", text: "Hello "}),
        signal(:text_delta, %{agent_id: "a1", text: "world"}),
        signal(:turn_finished, %{agent_id: "a1", result: {:ok, "Hello world"}})
      ]

      replay = fn ->
        Enum.reduce(signals, state(), fn sig, s ->
          {s, _effects} = SessionState.reduce(s, sig)
          s
        end)
      end

      assert replay.() == replay.()
    end
  end

  describe "text_delta" do
    test "buffers chunks in inflight" do
      s = state()
      {s, _} = reduce(s, :text_delta, %{agent_id: "a1", text: "hi"})

      assert %{"a1" => %{chunks: ["hi"]}} = s.inflight
    end

    test "accumulates multiple chunks" do
      s = state()
      {s, _} = reduce(s, :text_delta, %{agent_id: "a1", text: "a"})
      {s, _} = reduce(s, :text_delta, %{agent_id: "a1", text: "b"})

      assert %{"a1" => %{chunks: ["a", "b"]}} = s.inflight
    end

    test "emits push_event effect" do
      {_, effects} = reduce(state(), :text_delta, %{agent_id: "a1", text: "x"})

      assert {:push_event, "text-chunk", %{agent_id: "a1", text: "x"}} in effects
    end

    test "llm_text routes to same handler" do
      {s, _} = reduce(state(), :llm_text, %{agent_id: "a1", text: "y"})
      assert %{"a1" => %{chunks: ["y"]}} = s.inflight
    end
  end

  describe "tool_start" do
    test "appends tool_call message" do
      {s, _} =
        reduce(state(), :tool_start, %{
          agent_id: "a1",
          name: "bash",
          args: %{cmd: "ls"},
          call_id: "c1"
        })

      msgs = Map.get(s.agent_messages, "a1", [])
      assert [%{type: :tool_call, name: "bash", status: :pending}] = msgs
    end

    test "skips internal tools" do
      for name <- ["end_turn", "finish", "present_ui"] do
        {s, effects} =
          reduce(state(), :tool_start, %{agent_id: "a1", name: name})

        assert s.agent_messages == %{}
        assert effects == []
      end
    end

    test "flushes inflight chunks as thinking before tool" do
      s = state()
      {s, _} = reduce(s, :text_delta, %{agent_id: "a1", text: "thinking..."})

      {s, effects} =
        reduce(s, :tool_start, %{agent_id: "a1", name: "bash", call_id: "c1"})

      msgs = Map.get(s.agent_messages, "a1", [])
      assert [%{type: :thinking, content: "thinking..."}, %{type: :tool_call}] = msgs
      assert {:push_event, "stream-end", %{agent_id: "a1"}} in effects
    end
  end

  describe "tool_result" do
    test "updates existing pending tool_call by call_id" do
      s = state()

      {s, _} =
        reduce(s, :tool_start, %{
          agent_id: "a1",
          name: "bash",
          call_id: "c1"
        })

      {s, _} =
        reduce(s, :tool_result, %{
          agent_id: "a1",
          name: "bash",
          call_id: "c1",
          output: "file.txt",
          status: :ok
        })

      msgs = Map.get(s.agent_messages, "a1", [])
      assert [%{type: :tool_call, output: "file.txt", status: :ok}] = msgs
    end

    test "resets tokens on clear_memory" do
      s = state() |> Map.put(:total_input_tokens, 500) |> Map.put(:total_cost, 1.5)

      {s, _} =
        reduce(s, :tool_result, %{
          agent_id: "a1",
          name: "clear_memory",
          status: :ok
        })

      assert s.total_input_tokens == 0
      assert s.total_cost == 0.0
    end
  end

  describe "turn_started" do
    test "marks agent as busy" do
      s = state()

      {s, _} =
        reduce(s, :agent_started, %{agent_id: "a1", session_id: "s", role: :coder})

      {s, _} = reduce(s, :turn_started, %{agent_id: "a1"})

      assert s.agents["a1"].status == :busy
    end
  end

  describe "turn_finished" do
    test "marks agent as idle and adds result message" do
      s = state()

      {s, _} =
        reduce(s, :agent_started, %{agent_id: "a1", session_id: "s", role: :coder})

      {s, _} = reduce(s, :turn_started, %{agent_id: "a1"})

      {s, effects} =
        reduce(s, :turn_finished, %{agent_id: "a1", result: {:ok, "done"}})

      assert s.agents["a1"].status == :idle
      msgs = Map.get(s.agent_messages, "a1", [])
      assert [%{type: :text, content: "done"}] = msgs
      assert {:push_event, "stream-end", %{agent_id: "a1"}} in effects
    end

    test "adds error message on failure" do
      s = state()

      {s, _} =
        reduce(s, :agent_started, %{agent_id: "a1", session_id: "s", role: :coder})

      {s, _} =
        reduce(s, :turn_finished, %{agent_id: "a1", result: {:error, "boom"}})

      msgs = Map.get(s.agent_messages, "a1", [])
      assert [%{type: :error, content: "boom"}] = msgs
    end
  end

  describe "agent_started" do
    test "adds agent to state" do
      {s, _} =
        reduce(state(), :agent_started, %{
          agent_id: "a1",
          session_id: "s",
          role: :analyst,
          depth: 0,
          model: "claude"
        })

      assert %{role: :analyst, status: :idle, depth: 0} = s.agents["a1"]
      assert "a1" in s.agent_tab_order
      assert Map.has_key?(s.agent_messages, "a1")
    end

    test "does not duplicate tab order" do
      s = state()
      data = %{agent_id: "a1", session_id: "s", role: :coder}
      {s, _} = reduce(s, :agent_started, data)
      {s, _} = reduce(s, :agent_started, data)

      assert s.agent_tab_order == ["a1"]
    end
  end

  describe "agent_stopped" do
    test "removes ephemeral subagent (depth > 0)" do
      s = state()

      {s, _} =
        reduce(s, :agent_started, %{agent_id: "a1", session_id: "s", role: :sub, depth: 1})

      {s, _} = reduce(s, :agent_stopped, %{agent_id: "a1"})

      refute Map.has_key?(s.agents, "a1")
      refute "a1" in s.agent_tab_order
    end

    test "keeps primary agent but marks stopped" do
      s = state()

      {s, _} =
        reduce(s, :agent_started, %{
          agent_id: "a1",
          session_id: "s",
          role: :main,
          depth: 0
        })

      {s, _} = reduce(s, :agent_stopped, %{agent_id: "a1"})

      assert s.agents["a1"].status == :stopped
      assert "a1" in s.agent_tab_order
    end
  end

  describe "usage" do
    test "accumulates token counts" do
      s = state()

      {s, _} =
        reduce(s, :llm_usage, %{
          usage: %{input_tokens: 100, output_tokens: 50, total_cost: 0.01}
        })

      {s, _} =
        reduce(s, :llm_usage, %{
          usage: %{input_tokens: 200, output_tokens: 100, total_cost: 0.02}
        })

      assert s.total_input_tokens == 300
      assert s.total_output_tokens == 150
      assert_in_delta s.total_cost, 0.03, 0.001
      # step tokens reflect only the last step
      assert s.step_input_tokens == 200
      assert s.step_output_tokens == 100
    end
  end

  describe "message_sent" do
    test "uses pre-resolved labels" do
      {s, _} =
        reduce(state(), :message_sent, %{
          from: "a1",
          to: "a2",
          message: "hello",
          resolved_from_label: "analyst",
          resolved_target_agent_id: "a2"
        })

      msgs = Map.get(s.agent_messages, "a2", [])
      assert [%{content: "hello", from_agent: "analyst", agent_id: "a2"}] = msgs
    end

    test "falls back to raw values without enrichment" do
      {s, _} =
        reduce(state(), :message_sent, %{
          from: "a1",
          to: "a2",
          message: "hi"
        })

      msgs = Map.get(s.agent_messages, "a2", [])
      assert [%{content: "hi", from_agent: "a1"}] = msgs
    end
  end

  describe "ui_spec_delta" do
    test "first delta creates message and emits send_after" do
      {s, effects} =
        reduce(state(), :ui_spec_delta, %{
          agent_id: "a1",
          spec: %{type: "chart"},
          title: "My Chart",
          message_id: "m1"
        })

      msgs = Map.get(s.agent_messages, "a1", [])
      assert [%{type: :ui, streaming: true, spec: %{type: "chart"}}] = msgs
      assert {:send_after, 40, {:ui_spec_tick, "m1"}} in effects
    end

    test "subsequent deltas enqueue without new send_after" do
      s = state()

      {s, _} =
        reduce(s, :ui_spec_delta, %{
          agent_id: "a1",
          spec: %{v: 1},
          message_id: "m1"
        })

      {s, effects} =
        reduce(s, :ui_spec_delta, %{
          agent_id: "a1",
          spec: %{v: 2},
          message_id: "m1"
        })

      assert %{queue: [%{v: 2}]} = s.ui_streams["m1"]
      # No send_after for subsequent deltas
      refute Enum.any?(effects, &match?({:send_after, _, _}, &1))
    end
  end

  describe "task_requested / task_completed" do
    test "adds delegation messages" do
      s = state()

      {s, _} =
        reduce(s, :task_requested, %{agent_id: "a1", role: :analyst, task: "analyze"})

      {s, _} = reduce(s, :task_completed, %{agent_id: "a1", result: "done"})

      msgs = Map.get(s.agent_messages, "a1", [])
      assert [%{type: :delegation, status: :pending}, %{type: :delegation, status: :ok}] = msgs
    end
  end

  describe "step_start" do
    test "updates agent step and max_steps" do
      s = state()

      {s, _} =
        reduce(s, :agent_started, %{agent_id: "a1", session_id: "s", role: :coder})

      {s, _} =
        reduce(s, :step_start, %{agent_id: "a1", step: 3, max_steps: 10})

      assert s.agents["a1"].step == 3
      assert s.agents["a1"].max_steps == 10
    end
  end

  describe "before_llm" do
    test "stores debug projection with signal timestamp" do
      meta = %{emitted_at: 12_345}

      {s, _} =
        reduce(
          state(),
          :before_llm,
          %{agent_id: "a1", projection: %{context: [], tools: [], step: 1}},
          meta
        )

      assert %{timestamp: 12_345, step: 1} = s.debug_projections["a1"]
    end
  end

  describe "signals log" do
    test "add_signal appends to signals list with push_event effect" do
      {s, effects} =
        reduce(
          state(),
          :custom_event,
          %{agent_id: "a1"},
          %{emitted_at: 999}
        )

      assert [%{type: "custom_event", agent_id: "a1", timestamp: 999}] = s.signals
      assert Enum.any?(effects, &match?({:push_event, "signal", _}, &1))
    end

    test "signals are capped at 500" do
      s = state() |> Map.put(:signals, Enum.map(1..500, &%{id: &1}))

      {s, _} = reduce(s, :some_event, %{agent_id: "a1"})

      assert length(s.signals) == 500
    end
  end

  describe "ID generation" do
    test "next_id increments monotonically" do
      s = state()
      {s, _} = reduce(s, :turn_started, %{agent_id: "a1"})
      id_after_first = s.next_id

      {s, _} = reduce(s, :turn_started, %{agent_id: "a1"})
      assert s.next_id > id_after_first
    end
  end

  describe "catch-all" do
    test "unknown signal shape returns state unchanged" do
      s = state()
      {s2, effects} = SessionState.reduce(s, :garbage)
      assert s2 == s
      assert effects == []
    end
  end
end
