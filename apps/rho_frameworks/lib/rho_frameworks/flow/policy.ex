defmodule RhoFrameworks.Flow.Policy do
  @moduledoc """
  Strategy behaviour that picks the next node from a flow's allowed
  outgoing edges. Pluggable so the same flow can run deterministically
  in the wizard and BAML-routed in chat / co-pilot.

  Implementations:

    * `RhoFrameworks.Flow.Policies.Deterministic` — wizard. First-edge
      or first-satisfied-guard. Never calls an LLM. Ignores `:routing`.
    * `RhoFrameworks.Flow.Policies.Hybrid` (Phase 4) — chat / co-pilot.
      Dispatches on the node's `:routing` value (`:fixed | :auto |
      :agent_loop`).

  ## Contract

      choose_next(flow_mod, current_node, state, allowed_edges, opts)
        :: {:ok, atom() | :done, %{reason: String.t() | nil, confidence: float() | nil}}
         | {:error, term()}

  `allowed_edges` is the normalized list of `RhoFrameworks.Flow.edge_def`
  derived from `current_node.next` (a single atom is normalized to one
  edge; `:done` is normalized to `[%{to: :done}]`). Implementations
  receive the normalized list rather than re-deriving it.

  `opts` carries policy-specific knobs (e.g. user override, model
  config). Keep it loose — each policy documents its own keys.
  """

  alias RhoFrameworks.Flow

  @type decision :: %{reason: String.t() | nil, confidence: float() | nil}

  @callback choose_next(
              flow_mod :: module(),
              current_node :: Flow.node_def(),
              state :: map(),
              allowed_edges :: [Flow.edge_def()],
              opts :: keyword()
            ) ::
              {:ok, atom() | :done, decision()}
              | {:error, term()}
end
