defmodule RhoFrameworks.Flow.Policies.Hybrid do
  @moduledoc """
  Hybrid policy — chat / co-pilot mode. Dispatches on the node's
  `:routing` value:

    * 0 or 1 valid outgoing edge (after guard filtering) → first edge,
      no LLM. This short-circuit runs **before** the routing dispatch
      so single-edge nodes never call the router, even when authored
      with `routing: :auto`.
    * `routing: :fixed` → first satisfied guard (Deterministic
      semantics, no LLM).
    * `routing: :auto` → if `state.user_override[node_id]` names an
      allowed edge, use it directly. Else call the BAML router
      (`RhoFrameworks.LLM.ChooseNextFlowEdge` by default; overridable
      via `opts[:router_mod]` for tests). The returned `next_edge` is
      validated against the allowed set; an unrecognised value yields
      `{:error, :router_invalid_edge}`.
    * `routing: :agent_loop` → the node's UseCase has already spawned a
      worker via `run_node` (returning `{:async, ...}`). By the time
      `choose_next` is called the driver has either observed
      `:task_completed` or the user clicked "Continue early"
      (`AgentJobs.cancel/1`). The 0-or-1-edge short-circuit handles
      single-edge `:agent_loop` nodes (the §4b `:research` shape: one
      outgoing edge to `:generate`); for multi-edge agent_loop nodes the
      worker is expected to publish its chosen edge id into
      `state.summaries[node_id].chosen_edge`. Absent that, dispatch
      falls through to first-valid-edge (Deterministic semantics) so
      the policy never blocks the flow on a missing signal.

  ## Options

    * `:router_mod` — module implementing `call/2` returning
      `{:ok, %{next_edge: String.t(), confidence: float(),
      reasoning: String.t()}}`. Defaults to
      `RhoFrameworks.LLM.ChooseNextFlowEdge`.
    * `:router_args` — extra map merged into the router call args
      (e.g. an organisation-specific summary). Optional.
  """

  @behaviour RhoFrameworks.Flow.Policy

  alias RhoFrameworks.FlowRunner
  alias RhoFrameworks.LLM.ChooseNextFlowEdge

  @impl true
  def choose_next(_flow_mod, current_node, state, allowed_edges, opts) do
    valid = Enum.filter(allowed_edges, fn edge -> guard_satisfied?(edge, state) end)

    case valid do
      [] ->
        {:error, :no_satisfied_edge}

      [%{to: target}] ->
        {:ok, target, %{reason: nil, confidence: nil}}

      _ ->
        dispatch_routing(current_node, state, valid, opts)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Routing dispatch
  # ──────────────────────────────────────────────────────────────────────

  defp dispatch_routing(%{routing: :fixed}, _state, [%{to: target} | _], _opts) do
    # First satisfied guard — `valid` is already filtered.
    {:ok, target, %{reason: nil, confidence: nil}}
  end

  defp dispatch_routing(%{routing: :auto, id: node_id} = node, state, valid, opts) do
    case user_override(state, node_id, valid) do
      {:ok, target} ->
        {:ok, target, %{reason: "user override", confidence: 1.0}}

      :no_override ->
        call_router(node, state, valid, opts)
    end
  end

  defp dispatch_routing(%{routing: :agent_loop, id: node_id}, state, valid, _opts) do
    case worker_chosen_edge(state, node_id, valid) do
      {:ok, target} ->
        {:ok, target,
         %{reason: "agent_loop worker selected #{Atom.to_string(target)}", confidence: 1.0}}

      :no_signal ->
        # No multi-edge selection signal: take the first valid edge. For
        # single-edge :agent_loop nodes the 0-or-1 short-circuit already
        # picked it before we got here, so this branch only fires on
        # multi-edge nodes whose worker didn't publish a chosen_edge.
        %{to: target} = hd(valid)

        {:ok, target, %{reason: "agent_loop fell through to first valid edge", confidence: nil}}
    end
  end

  defp dispatch_routing(%{routing: routing}, _state, _valid, _opts) do
    {:error, {:unknown_routing, routing}}
  end

  # ──────────────────────────────────────────────────────────────────────
  # User override
  # ──────────────────────────────────────────────────────────────────────

  defp user_override(state, node_id, valid) do
    case Map.get(state, :user_override, %{}) do
      %{} = overrides ->
        case Map.get(overrides, node_id) do
          chosen when is_atom(chosen) ->
            if Enum.any?(valid, fn %{to: t} -> t == chosen end),
              do: {:ok, chosen},
              else: :no_override

          _ ->
            :no_override
        end

      _ ->
        :no_override
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # BAML router call
  # ──────────────────────────────────────────────────────────────────────

  defp call_router(node, state, valid, opts) do
    router = Keyword.get(opts, :router_mod, ChooseNextFlowEdge)

    args =
      %{
        current_label: Map.get(node, :label, Atom.to_string(node.id)),
        allowed: format_allowed(valid),
        summary: format_summary(state)
      }
      |> Map.merge(Keyword.get(opts, :router_args, %{}))

    case router.call(args) do
      {:ok, %{next_edge: next_edge_str, confidence: confidence, reasoning: reasoning}} ->
        validate_router_choice(next_edge_str, valid, confidence, reasoning)

      {:error, reason} ->
        {:error, {:router_failed, reason}}
    end
  end

  defp validate_router_choice(next_edge_str, valid, confidence, reasoning)
       when is_binary(next_edge_str) do
    allowed_ids = Enum.map(valid, & &1.to)

    case Enum.find(allowed_ids, fn id -> Atom.to_string(id) == next_edge_str end) do
      nil ->
        {:error, :router_invalid_edge}

      target ->
        {:ok, target, %{reason: reasoning, confidence: confidence}}
    end
  end

  defp validate_router_choice(_, _, _, _), do: {:error, :router_invalid_edge}

  # ──────────────────────────────────────────────────────────────────────
  # Worker-chosen edge (multi-edge :agent_loop)
  # ──────────────────────────────────────────────────────────────────────

  defp worker_chosen_edge(state, node_id, valid) do
    summaries = Map.get(state, :summaries, %{})

    case summaries |> Map.get(node_id, %{}) |> Map.get(:chosen_edge) do
      chosen when is_atom(chosen) ->
        if Enum.any?(valid, fn %{to: t} -> t == chosen end),
          do: {:ok, chosen},
          else: :no_signal

      _ ->
        :no_signal
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────

  defp guard_satisfied?(edge, state) do
    case Map.get(edge, :guard) do
      nil -> true
      guard when is_atom(guard) -> FlowRunner.guard?(guard, state)
    end
  end

  defp format_allowed(valid) do
    valid
    |> Enum.map(fn %{to: id} = edge ->
      label = Map.get(edge, :label) || Atom.to_string(id)
      "  - #{Atom.to_string(id)} — #{label}"
    end)
    |> Enum.join("\n")
  end

  defp format_summary(state) do
    summaries = Map.get(state, :summaries, %{})

    if map_size(summaries) == 0 do
      "(no prior summaries)"
    else
      summaries
      |> Enum.map(fn {node_id, summary} ->
        "  - #{Atom.to_string(node_id)}: #{inspect(summary, limit: 5, printable_limit: 200)}"
      end)
      |> Enum.join("\n")
    end
  end
end
