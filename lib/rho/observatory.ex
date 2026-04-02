defmodule Rho.Observatory do
  @moduledoc """
  Metrics collector for observing the multi-agent system.

  Subscribes to the signal bus and accumulates per-agent and per-session
  metrics: step counts, tool call stats, token usage, errors, latencies,
  and signal flow between agents.
  """

  use GenServer

  require Logger

  @max_tool_calls 100
  @max_latencies 200
  @max_errors 50
  @max_turn_durations 100
  @max_flows 500

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get aggregated metrics for a session."
  def session_metrics(session_id) do
    GenServer.call(__MODULE__, {:session_metrics, session_id})
  end

  @doc "Get detailed metrics for a specific agent."
  def agent_metrics(agent_id) do
    GenServer.call(__MODULE__, {:agent_metrics, agent_id})
  end

  @doc "Get the signal flow graph for a session (who talked to whom)."
  def signal_flow(session_id) do
    GenServer.call(__MODULE__, {:signal_flow, session_id})
  end

  @doc "Get recent events for a session (last N)."
  def recent_events(session_id, limit \\ 50) do
    GenServer.call(__MODULE__, {:recent_events, session_id, limit})
  end

  @doc "Run diagnostic heuristics on a session."
  def diagnose(session_id) do
    GenServer.call(__MODULE__, {:diagnose, session_id})
  end

  @doc "List all sessions with activity."
  def sessions do
    GenServer.call(__MODULE__, :sessions)
  end

  @doc "Reset metrics for a session."
  def reset(session_id) do
    GenServer.cast(__MODULE__, {:reset, session_id})
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    # Subscribe to all session events and agent lifecycle
    {:ok, sub1} = Rho.Comms.subscribe("rho.session.*.events.*")
    {:ok, sub2} = Rho.Comms.subscribe("rho.agent.*")
    {:ok, sub3} = Rho.Comms.subscribe("rho.task.*")

    state = %{
      subscriptions: [sub1, sub2, sub3],
      # %{session_id => %{agent_id => agent_metrics}}
      metrics: %{},
      # %{session_id => [event, ...]} (capped ring buffer)
      events: %{},
      # %{session_id => [{from_agent, to_agent, type, timestamp}, ...]}
      flows: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:signal, %{type: type, data: data}}, state) do
    state = process_signal(type, data, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:session_metrics, session_id}, _from, state) do
    session_data = Map.get(state.metrics, session_id, %{})

    # Also pull live info from registry
    live_agents =
      Rho.Agent.Registry.list(session_id)
      |> Enum.map(fn agent ->
        pid = agent.pid
        live_info = try do
          Rho.Agent.Worker.info(pid)
        catch
          :exit, _ -> nil
        end
        {agent.agent_id, live_info}
      end)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    summary = %{
      session_id: session_id,
      agent_count: map_size(live_agents),
      agents: Enum.map(session_data, fn {agent_id, m} ->
        live = Map.get(live_agents, agent_id, %{})
        Map.merge(m, %{
          agent_id: agent_id,
          status: live[:status],
          current_step: live[:current_step],
          current_tool: live[:current_tool],
          queued: live[:queued]
        })
      end),
      total_tokens: session_data |> Enum.reduce(0, fn {_, m}, acc -> acc + (m[:total_input_tokens] || 0) + (m[:total_output_tokens] || 0) end),
      total_tool_calls: session_data |> Enum.reduce(0, fn {_, m}, acc -> acc + (m[:tool_call_count] || 0) end),
      total_errors: session_data |> Enum.reduce(0, fn {_, m}, acc -> acc + (m[:error_count] || 0) end)
    }

    {:reply, summary, state}
  end

  def handle_call({:agent_metrics, agent_id}, _from, state) do
    # Find agent across all sessions
    result =
      Enum.find_value(state.metrics, fn {_sid, agents} ->
        Map.get(agents, agent_id)
      end)

    {:reply, result || %{}, state}
  end

  def handle_call({:signal_flow, session_id}, _from, state) do
    flows = Map.get(state.flows, session_id, [])
    {:reply, flows, state}
  end

  def handle_call({:recent_events, session_id, limit}, _from, state) do
    events = Map.get(state.events, session_id, [])
    {:reply, Enum.take(events, limit), state}
  end

  def handle_call({:diagnose, session_id}, _from, state) do
    diagnostics = run_diagnostics(session_id, state)
    {:reply, diagnostics, state}
  end

  def handle_call(:sessions, _from, state) do
    session_ids = Map.keys(state.metrics)
    summaries = Enum.map(session_ids, fn sid ->
      agents = Map.get(state.metrics, sid, %{})
      %{
        session_id: sid,
        agent_count: map_size(agents),
        live_agents: Rho.Agent.Registry.count(sid)
      }
    end)
    {:reply, summaries, state}
  end

  @impl true
  def handle_cast({:reset, session_id}, state) do
    state = %{state |
      metrics: Map.delete(state.metrics, session_id),
      events: Map.delete(state.events, session_id),
      flows: Map.delete(state.flows, session_id)
    }
    {:noreply, state}
  end

  # --- Signal Processing ---

  defp process_signal(type, data, state) do
    session_id = data[:session_id]
    agent_id = data[:agent_id]

    unless session_id do
      state
    else
      state = record_event(state, session_id, type, data)

      cond do
        String.contains?(type, "events.tool_start") ->
          update_agent_metric(state, session_id, agent_id, fn m ->
            tools = Map.get(m, :tool_calls, [])
            %{m | tool_calls: Enum.take([%{name: data[:name], args: data[:args], started_at: now()} | tools], @max_tool_calls)}
            |> Map.update(:tool_call_count, 1, &(&1 + 1))
          end)

        String.contains?(type, "events.tool_result") ->
          update_agent_metric(state, session_id, agent_id, fn m ->
            latency = data[:latency_ms] || 0
            latencies = Map.get(m, :tool_latencies, [])
            error_bump = if data[:status] == :error, do: 1, else: 0

            tool_name = case m[:tool_calls] do
              [%{name: n} | _] -> n
              _ -> "unknown"
            end

            tool_stats = Map.get(m, :tool_stats, %{})
            ts = Map.get(tool_stats, tool_name, %{count: 0, errors: 0, total_ms: 0})
            ts = %{ts | count: ts.count + 1, errors: ts.errors + error_bump, total_ms: ts.total_ms + latency}

            %{m |
              tool_latencies: Enum.take([latency | latencies], @max_latencies),
              tool_stats: Map.put(tool_stats, tool_name, ts),
              error_count: (m[:error_count] || 0) + error_bump
            }
          end)

        String.contains?(type, "events.llm_usage") ->
          usage = data[:usage] || %{}
          update_agent_metric(state, session_id, agent_id, fn m ->
            %{m |
              total_input_tokens: (m[:total_input_tokens] || 0) + (usage[:input_tokens] || 0),
              total_output_tokens: (m[:total_output_tokens] || 0) + (usage[:output_tokens] || 0),
              cached_tokens: (m[:cached_tokens] || 0) + (usage[:cached_tokens] || 0),
              llm_calls: (m[:llm_calls] || 0) + 1,
              cost: (m[:cost] || 0) + (data[:cost] || 0)
            }
          end)

        String.contains?(type, "events.step_start") ->
          update_agent_metric(state, session_id, agent_id, fn m ->
            %{m | step_count: (m[:step_count] || 0) + 1}
          end)

        String.contains?(type, "events.error") ->
          update_agent_metric(state, session_id, agent_id, fn m ->
            errors = Map.get(m, :errors, [])
            %{m |
              errors: Enum.take([%{message: data[:message], at: now()} | errors], @max_errors),
              error_count: (m[:error_count] || 0) + 1
            }
          end)

        String.contains?(type, "events.turn_started") ->
          update_agent_metric(state, session_id, agent_id, fn m ->
            %{m | turn_count: (m[:turn_count] || 0) + 1, last_turn_started: now()}
          end)

        String.contains?(type, "events.turn_finished") ->
          update_agent_metric(state, session_id, agent_id, fn m ->
            started = m[:last_turn_started] || now()
            duration = now() - started
            %{m | turn_durations: Enum.take([duration | Map.get(m, :turn_durations, [])], @max_turn_durations)}
          end)

        String.contains?(type, "task.requested") ->
          flow_entry = %{
            from: data[:agent_id],
            to: data[:target_agent_id] || "new",
            type: :delegation,
            at: now()
          }
          update_flows(state, session_id, flow_entry)

        String.contains?(type, "task.completed") ->
          flow_entry = %{
            from: data[:agent_id],
            to: "parent",
            type: :result,
            at: now()
          }
          update_flows(state, session_id, flow_entry)

        true ->
          state
      end
    end
  end

  defp update_agent_metric(state, session_id, agent_id, fun) when is_binary(agent_id) do
    session_metrics = Map.get(state.metrics, session_id, %{})
    agent_metric = Map.get(session_metrics, agent_id, default_metrics())
    agent_metric = fun.(agent_metric)
    session_metrics = Map.put(session_metrics, agent_id, agent_metric)
    %{state | metrics: Map.put(state.metrics, session_id, session_metrics)}
  end

  defp update_agent_metric(state, _session_id, _agent_id, _fun), do: state

  defp update_flows(state, session_id, entry) do
    flows = Map.get(state.flows, session_id, [])
    %{state | flows: Map.put(state.flows, session_id, Enum.take([entry | flows], @max_flows))}
  end

  defp record_event(state, session_id, type, data) do
    event = %{type: type, data: Map.take(data, [:agent_id, :name, :status, :message, :latency_ms]), at: now()}
    events = Map.get(state.events, session_id, [])
    # Keep last 200 events per session
    events = [event | Enum.take(events, 199)]
    %{state | events: Map.put(state.events, session_id, events)}
  end

  defp default_metrics do
    %{
      step_count: 0,
      tool_call_count: 0,
      tool_calls: [],
      tool_latencies: [],
      tool_stats: %{},
      total_input_tokens: 0,
      total_output_tokens: 0,
      cached_tokens: 0,
      llm_calls: 0,
      cost: 0,
      error_count: 0,
      errors: [],
      turn_count: 0,
      turn_durations: [],
      last_turn_started: nil,
      status: :idle,
      current_step: 0,
      current_tool: nil,
      queued: 0
    }
  end

  defp now, do: System.monotonic_time(:millisecond)

  # --- Diagnostics ---

  defp run_diagnostics(session_id, state) do
    session_data = Map.get(state.metrics, session_id, %{})

    issues =
      Enum.flat_map(session_data, fn {agent_id, m} ->
        check_error_rate(agent_id, m) ++
          check_large_context(agent_id, m) ++
          check_tool_hotspot(agent_id, m) ++
          check_slow_tools(agent_id, m) ++
          check_step_count(agent_id, m)
      end)

    %{
      session_id: session_id,
      issues: issues,
      summary: %{
        total_issues: length(issues),
        warnings: Enum.count(issues, &(&1.severity == :warning)),
        info: Enum.count(issues, &(&1.severity == :info))
      }
    }
  end

  defp check_error_rate(agent_id, m) do
    tool_count = m[:tool_call_count] || 0
    error_count = m[:error_count] || 0

    if tool_count > 0 and error_count / tool_count > 0.3 do
      [%{
        severity: :warning,
        agent_id: agent_id,
        issue: "high_error_rate",
        detail: "#{Float.round(error_count / tool_count * 100, 1)}% of tool calls failed",
        suggestion: "Check tool arguments and permissions"
      }]
    else
      []
    end
  end

  defp check_large_context(agent_id, m) do
    input = m[:total_input_tokens] || 0
    calls = m[:llm_calls] || 0

    if input > 50_000 and calls > 3 do
      avg = div(input, calls)
      if avg > 20_000 do
        [%{
          severity: :info,
          agent_id: agent_id,
          issue: "large_context",
          detail: "Avg #{avg} input tokens/call (#{calls} calls)",
          suggestion: "Consider enabling compaction or reducing prompt size"
        }]
      else
        []
      end
    else
      []
    end
  end

  defp check_tool_hotspot(agent_id, m) do
    tool_stats = m[:tool_stats] || %{}

    if map_size(tool_stats) > 0 do
      {hottest, hot_stats} = Enum.max_by(tool_stats, fn {_, s} -> s.count end)
      total = Enum.reduce(tool_stats, 0, fn {_, s}, acc -> acc + s.count end)

      if total > 5 and hot_stats.count / total > 0.6 do
        [%{
          severity: :info,
          agent_id: agent_id,
          issue: "tool_hotspot",
          detail: "#{hottest} accounts for #{round(hot_stats.count / total * 100)}% of tool calls",
          suggestion: "Check if agent is stuck in a loop with this tool"
        }]
      else
        []
      end
    else
      []
    end
  end

  defp check_slow_tools(agent_id, m) do
    tool_stats = m[:tool_stats] || %{}

    Enum.flat_map(tool_stats, fn {name, stats} ->
      if stats.count > 0 and stats.total_ms / stats.count > 5000 do
        [%{
          severity: :warning,
          agent_id: agent_id,
          issue: "slow_tool",
          detail: "#{name} averages #{round(stats.total_ms / stats.count)}ms per call",
          suggestion: "Consider timeouts or async execution"
        }]
      else
        []
      end
    end)
  end

  defp check_step_count(agent_id, m) do
    if (m[:step_count] || 0) > 20 do
      [%{
        severity: :warning,
        agent_id: agent_id,
        issue: "many_steps",
        detail: "#{m[:step_count]} steps taken",
        suggestion: "May indicate agent is struggling; check system prompt clarity"
      }]
    else
      []
    end
  end
end
