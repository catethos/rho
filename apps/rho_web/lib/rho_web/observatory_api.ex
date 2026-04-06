defmodule RhoWeb.ObservatoryAPI do
  @moduledoc """
  JSON API for observing the multi-agent system.

  Exposes metrics, diagnostics, signal flow, and agent state
  for external tools (like Claude Code) to consume.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case {conn.method, conn.path_info} do
      {"GET", ["sessions"]} ->
        handle_sessions(conn)

      {"GET", ["sessions", session_id, "metrics"]} ->
        handle_session_metrics(conn, session_id)

      {"GET", ["sessions", session_id, "agents"]} ->
        handle_session_agents(conn, session_id)

      {"GET", ["sessions", session_id, "signals"]} ->
        handle_signal_flow(conn, session_id)

      {"GET", ["sessions", session_id, "events"]} ->
        handle_recent_events(conn, session_id)

      {"GET", ["sessions", session_id, "diagnose"]} ->
        handle_diagnose(conn, session_id)

      {"GET", ["agents", agent_id, "metrics"]} ->
        handle_agent_metrics(conn, agent_id)

      {"GET", ["agents", agent_id, "tape"]} ->
        handle_agent_tape(conn, agent_id)

      {"POST", ["sessions", session_id, "submit"]} ->
        handle_submit(conn, session_id)

      {"POST", ["sessions", session_id, "ask"]} ->
        handle_ask(conn, session_id)

      {"POST", ["sessions"]} ->
        handle_create_session(conn)

      {"POST", ["sessions", session_id, "inject"]} ->
        handle_inject(conn, session_id)

      {"GET", ["sessions", session_id, "log"]} ->
        handle_event_log(conn, session_id)

      {"GET", ["health"]} ->
        json(conn, 200, %{status: "ok", observatory: true})

      _ ->
        json(conn, 404, %{error: "not_found"})
    end
  end

  # --- Handlers ---

  defp handle_sessions(conn) do
    sessions = RhoWeb.Observatory.sessions()

    # Also check for live sessions without observatory data
    live_sessions = Rho.Agent.Primary.list()
    live_ids = MapSet.new(Enum.map(live_sessions, & &1.session_id))
    obs_ids = MapSet.new(Enum.map(sessions, & &1.session_id))

    extra =
      MapSet.difference(live_ids, obs_ids)
      |> Enum.map(fn sid ->
        %{session_id: sid, agent_count: 0, live_agents: Rho.Agent.Registry.count(sid)}
      end)

    json(conn, 200, %{sessions: sessions ++ extra})
  end

  defp handle_session_metrics(conn, session_id) do
    metrics = RhoWeb.Observatory.session_metrics(session_id)
    json(conn, 200, metrics)
  end

  defp handle_session_agents(conn, session_id) do
    agents =
      Rho.Agent.Registry.list_all(session_id)
      |> Enum.map(fn agent ->
        live_info =
          try do
            pid = agent.pid

            if pid && Process.alive?(pid) do
              Rho.Agent.Worker.info(pid)
            else
              nil
            end
          catch
            :exit, _ -> nil
          end

        base = %{
          agent_id: agent.agent_id,
          role: agent.role,
          status: agent.status,
          depth: agent.depth,
          capabilities: agent.capabilities,
          description: agent.description
        }

        if live_info do
          Map.merge(base, %{
            current_step: live_info[:current_step],
            current_tool: live_info[:current_tool],
            token_usage: live_info[:token_usage],
            queued: live_info[:queued],
            agent_name: live_info[:agent_name],
            tape: sanitize_tape_info(live_info[:tape])
          })
        else
          base
        end
      end)

    json(conn, 200, %{session_id: session_id, agents: agents})
  end

  defp handle_signal_flow(conn, session_id) do
    flows = RhoWeb.Observatory.signal_flow(session_id)
    json(conn, 200, %{session_id: session_id, flows: flows})
  end

  defp handle_recent_events(conn, session_id) do
    limit = conn.params["limit"] |> parse_int(50)
    events = RhoWeb.Observatory.recent_events(session_id, limit)
    json(conn, 200, %{session_id: session_id, events: events})
  end

  defp handle_diagnose(conn, session_id) do
    diagnostics = RhoWeb.Observatory.diagnose(session_id)
    json(conn, 200, diagnostics)
  end

  defp handle_agent_metrics(conn, agent_id) do
    metrics = RhoWeb.Observatory.agent_metrics(agent_id)
    json(conn, 200, %{agent_id: agent_id, metrics: metrics})
  end

  defp handle_agent_tape(conn, agent_id) do
    agent = Rho.Agent.Registry.get(agent_id)

    if agent && agent.tape_ref do
      memory_mod = Rho.Config.tape_module()
      history = memory_mod.history(agent.tape_ref)

      # Return last N entries (tape can be large)
      limit = conn.params["limit"] |> parse_int(20)

      entries =
        Enum.take(history, -limit)
        |> Enum.map(&sanitize_tape_entry/1)

      info = memory_mod.info(agent.tape_ref)

      json(conn, 200, %{
        agent_id: agent_id,
        tape_info: sanitize_tape_info(info),
        entries: entries
      })
    else
      json(conn, 404, %{error: "agent not found or no tape"})
    end
  end

  defp handle_submit(conn, session_id) do
    params = conn.body_params
    content = params["content"] || params["message"]

    pid =
      case Rho.Agent.Primary.whereis(session_id) do
        nil ->
          {:ok, p} = Rho.Agent.Primary.ensure_started(session_id)
          p

        p ->
          p
      end

    {:ok, turn_id} = Rho.Agent.Worker.submit(pid, content)
    json(conn, 200, %{turn_id: turn_id, status: "submitted"})
  end

  defp handle_ask(conn, session_id) do
    params = conn.body_params
    content = params["content"] || params["message"]
    await = if params["await"] == "finish", do: :finish, else: :turn

    # Ensure session exists
    {:ok, pid} = Rho.Agent.Primary.ensure_started(session_id)

    # Synchronous — blocks until turn finishes (or until `finish` in simulation mode)
    result = Rho.Agent.Worker.ask(pid, content, await: await)

    case result do
      {:ok, text} ->
        json(conn, 200, %{result: text, status: "completed"})

      {:error, reason} ->
        json(conn, 422, %{error: inspect(reason), status: "error"})

      other ->
        json(conn, 200, %{result: inspect(other), status: "completed"})
    end
  end

  defp handle_create_session(conn) do
    params = conn.body_params
    session_id = params["session_id"] || Rho.Agent.Primary.new_id()
    workspace = params["workspace"]

    case Rho.Agent.Primary.validate_session_id(session_id) do
      {:error, :invalid_session_id} ->
        json(conn, 400, %{error: "invalid session_id"})

      :ok ->
        opts = if workspace, do: [workspace: workspace], else: []
        {:ok, pid} = Rho.Agent.Primary.ensure_started(session_id, opts)

        result = %{session_id: session_id, status: "started"}

        # Optionally submit an initial message
        case params["message"] do
          nil ->
            json(conn, 200, result)

          message ->
            {:ok, turn_id} = Rho.Agent.Worker.submit(pid, message)
            json(conn, 200, Map.put(result, :turn_id, turn_id))
        end
    end
  end

  defp handle_inject(conn, session_id) do
    params = conn.body_params
    target = params["target"]
    message = params["message"]
    from = params["from"]

    target_agent_id =
      cond do
        target in [nil, "primary"] -> nil
        true -> target
      end

    opts = if from, do: [from: from], else: []

    case Rho.Agent.Primary.inject(session_id, target_agent_id, message, opts) do
      {:ok, _} ->
        json(conn, 200, %{status: "injected"})

      {:error, :agent_not_found} ->
        json(conn, 404, %{error: "agent_not_found", target: target})

      {:error, reason} ->
        json(conn, 400, %{error: inspect(reason)})
    end
  end

  defp handle_event_log(conn, session_id) do
    after_seq = conn.params["after"] |> parse_int(0)
    limit = conn.params["limit"] |> parse_int(100)

    {events, last_seq} = Rho.Agent.EventLog.read(session_id, after: after_seq, limit: limit)
    has_more = length(events) >= limit

    json(conn, 200, %{
      events: events,
      cursor: last_seq,
      has_more: has_more
    })
  end

  # --- Helpers ---

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
    |> halt()
  end

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_, default), do: default

  defp sanitize_tape_info(nil), do: nil

  defp sanitize_tape_info(info) when is_map(info) do
    Map.take(info, [:entry_count, :anchor_count, :kind_counts, :byte_size])
    |> Map.new(fn {k, v} -> {k, v} end)
  end

  defp sanitize_tape_info(_), do: nil

  defp sanitize_tape_entry(entry) when is_map(entry) do
    # Keep structure but truncate large payloads
    payload =
      case entry[:payload] || entry["payload"] do
        p when is_binary(p) and byte_size(p) > 500 ->
          String.slice(p, 0, 500) <> "... [truncated]"

        p ->
          p
      end

    %{
      kind: entry[:kind] || entry["kind"],
      payload: payload,
      meta: entry[:meta] || entry["meta"],
      inserted_at: entry[:inserted_at] || entry["inserted_at"]
    }
  end

  defp sanitize_tape_entry(entry), do: entry
end
