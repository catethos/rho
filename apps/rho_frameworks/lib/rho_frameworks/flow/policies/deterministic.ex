defmodule RhoFrameworks.Flow.Policies.Deterministic do
  @moduledoc """
  Deterministic policy — wizard / Guided mode.

  Picks the first edge whose guard is satisfied. Single-edge nodes pass
  through (no guard needed). Never calls an LLM. **Ignores the node's
  `:routing` value** — that lever is for the Hybrid policy (Phase 4).

  Returns `confidence: nil, reason: nil` — the reasoning field is only
  populated by LLM-based policies.
  """

  @behaviour RhoFrameworks.Flow.Policy

  alias RhoFrameworks.FlowRunner

  @impl true
  def choose_next(_flow_mod, _current_node, state, allowed_edges, _opts) do
    case Enum.find(allowed_edges, fn edge -> guard_satisfied?(edge, state) end) do
      nil ->
        {:error, :no_satisfied_edge}

      %{to: target} ->
        {:ok, target, %{reason: nil, confidence: nil}}
    end
  end

  defp guard_satisfied?(edge, state) do
    case Map.get(edge, :guard) do
      nil -> true
      guard when is_atom(guard) -> FlowRunner.guard?(guard, state)
    end
  end
end
