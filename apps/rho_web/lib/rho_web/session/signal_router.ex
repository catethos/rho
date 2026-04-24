defmodule RhoWeb.Session.SignalRouter do
  @moduledoc """
  Routes signals to the appropriate reducers and applies state to socket.

  The router runs `SessionState` (pure reducer) + `SessionEffects` (impure
  applicator), then dispatches to any matching workspace projections via
  `handles?/1`. Workspace projection state is stored in a single `ws_states`
  assign.
  """

  import Phoenix.Component, only: [assign: 3]

  alias RhoWeb.Projections.SessionState
  alias RhoWeb.Session.SessionEffects
  alias RhoWeb.Session.Shell

  # Session state fields that live in socket assigns.
  # :next_id is internal to the reducer, stored alongside but not displayed.
  @state_fields [
    :agents,
    :agent_tab_order,
    :agent_messages,
    :inflight,
    :signals,
    :ui_streams,
    :debug_projections,
    :selected_agent_id,
    :total_input_tokens,
    :total_output_tokens,
    :total_cost,
    :total_cached_tokens,
    :total_reasoning_tokens,
    :step_input_tokens,
    :step_output_tokens,
    :next_id
  ]

  @doc """
  Route a signal through all applicable projections.

  Pipeline: enrich → session state → workspace states → shell → effects.

  Pure reduction (session state, workspace projections, shell chrome) is
  separated from impure effect application (push_event, timers). Effects
  are collected as data during the pure stages and applied at the end.
  """
  def route(socket, signal, workspace_modules) do
    t0 = System.monotonic_time(:microsecond)
    signal = enrich_signal(signal, socket)

    result =
      socket
      |> init_pipeline()
      |> update_session_state(signal)
      |> update_workspace_states(signal, workspace_modules)
      |> update_shell(signal, workspace_modules)
      |> apply_effects()

    dt = System.monotonic_time(:microsecond) - t0

    :telemetry.execute(
      [:rho, :signal, :route],
      %{duration_us: dt},
      %{signal_type: signal.type}
    )

    result
  end

  # --- Pipeline stages ---

  defp init_pipeline(socket) do
    socket
    |> assign(:_effects, [])
    |> assign(:_changed_ws_keys, MapSet.new())
  end

  # Stage 1: Pure session state reduction
  defp update_session_state(socket, signal) do
    state = extract_state(socket)
    {new_state, effects} = SessionState.reduce(state, signal)

    socket
    |> write_state(new_state)
    |> collect_effects(effects)
  end

  # Stage 2: Pure workspace projection reduction
  defp update_workspace_states(socket, signal, workspace_modules) do
    Enum.reduce(workspace_modules, socket, fn mod, sock ->
      projection = mod.projection()

      if projection.handles?(signal.type) do
        reduce_workspace(sock, mod.key(), projection, signal)
      else
        sock
      end
    end)
  end

  defp reduce_workspace(sock, key, projection, signal) do
    ws_state = read_ws_state(sock, key)
    new_ws_state = projection.reduce(ws_state, signal)
    sock = write_ws_state(sock, key, new_ws_state)

    if new_ws_state != ws_state do
      changed = MapSet.put(sock.assigns._changed_ws_keys, key)
      assign(sock, :_changed_ws_keys, changed)
    else
      sock
    end
  end

  # Stage 3: Pure shell chrome reduction (activity tracking + auto-open)
  defp update_shell(socket, signal, workspace_modules) do
    active_ws = socket.assigns[:active_workspace_id]
    correlation_id = signal.data[:correlation_id]
    changed_keys = socket.assigns._changed_ws_keys

    Enum.reduce(workspace_modules, socket, fn mod, sock ->
      key = mod.key()

      if MapSet.member?(changed_keys, key) do
        update_shell_for_key(sock, key, mod, active_ws, correlation_id)
      else
        sock
      end
    end)
  end

  defp update_shell_for_key(sock, key, mod, active_ws, correlation_id) do
    shell = Shell.record_activity(sock.assigns.shell, key, active_ws)
    shell = maybe_auto_open_shell(shell, key, mod, correlation_id)

    sock =
      if shell.workspaces[key] && shell.workspaces[key].pulse do
        collect_effects(sock, [{:send_after, 3_000, {:clear_pulse, key}}])
      else
        sock
      end

    assign(sock, :shell, shell)
  end

  defp maybe_auto_open_shell(shell, key, mod, correlation_id) do
    if mod.auto_open?() do
      {updated_shell, _opened?} = Shell.maybe_auto_open(shell, key, correlation_id)
      updated_shell
    else
      shell
    end
  end

  # Stage 4: Apply all collected effects (impure boundary)
  defp apply_effects(socket) do
    effects = socket.assigns._effects

    socket
    |> SessionEffects.apply(effects)
    |> cleanup_pipeline()
  end

  defp collect_effects(socket, new_effects) do
    assign(socket, :_effects, socket.assigns._effects ++ new_effects)
  end

  defp cleanup_pipeline(socket) do
    # Remove temporary pipeline assigns via raw assign map update
    assigns =
      socket.assigns
      |> Map.delete(:_effects)
      |> Map.delete(:_changed_ws_keys)

    %{socket | assigns: assigns}
  end

  @doc "Read a workspace's projection state from the ws_states assign."
  def read_ws_state(socket, key) do
    get_in(socket.assigns, [:ws_states, key])
  end

  @doc "Write a workspace's projection state into the ws_states assign."
  def write_ws_state(socket, key, state) do
    ws_states = Map.put(socket.assigns.ws_states, key, state)
    assign(socket, :ws_states, ws_states)
  end

  @doc """
  Appends a message to the agent_messages in socket assigns.

  Convenience wrapper around `SessionState.append_message/2` for code
  that operates on sockets (e.g. SessionCore.send_message).
  """
  def append_message(socket, msg) do
    state = extract_state(socket)
    state = SessionState.append_message(state, msg)
    write_state(socket, state)
  end

  # --- Private ---

  defp extract_state(socket) do
    assigns = socket.assigns

    state =
      Map.new(@state_fields, fn key ->
        {key, Map.get(assigns, key)}
      end)

    Map.put(state, :session_id, assigns[:session_id])
  end

  defp write_state(socket, state) do
    Enum.reduce(@state_fields, socket, fn key, sock ->
      assign(sock, key, Map.get(state, key))
    end)
  end

  defp enrich_signal(%{type: type, data: data} = signal, socket) when is_binary(type) do
    if String.ends_with?(type, ".message_sent") do
      enriched_data = enrich_message_sent(data, socket)
      %{signal | data: enriched_data}
    else
      signal
    end
  end

  defp enrich_signal(signal, _socket), do: signal

  defp enrich_message_sent(data, socket) do
    from = data[:from]
    to = data[:to]

    from_label =
      case Rho.Agent.Registry.get(from) do
        %{role: role} -> to_string(role)
        _ -> from || "unknown"
      end

    data
    |> Map.put(:resolved_from_label, from_label)
    |> Map.put(:resolved_target_agent_id, resolve_target_agent_id(to, socket))
  end

  defp resolve_target_agent_id(to, socket) do
    case Rho.Agent.Worker.whereis(to) do
      pid when is_pid(pid) -> to
      nil -> resolve_target_by_role(to, socket.assigns.session_id)
    end
  end

  defp resolve_target_by_role(to, session_id) do
    role_atom =
      try do
        String.to_existing_atom(to)
      rescue
        ArgumentError -> nil
      end

    case role_atom && Rho.Agent.Registry.find_by_role(session_id, role_atom) do
      [agent | _] -> agent.agent_id
      _ -> to
    end
  end
end
