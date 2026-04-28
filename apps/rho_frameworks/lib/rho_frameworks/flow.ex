defmodule RhoFrameworks.Flow do
  @moduledoc """
  Behaviour for step-by-step wizard / co-pilot flows.

  A flow is a list of nodes connected by explicit edges. Each node
  references a `RhoFrameworks.UseCase` (or is a UI-only step) and declares
  how the next node is chosen via the per-node `:routing` value:

    * `:fixed`      — single edge or first-satisfied guard, no LLM
    * `:auto`       — BAML router picks from allowed edges (Phase 4)
    * `:agent_loop` — escalate to an `AgentJobs` worker (Phase 4)

  The Flow author owns this choice — there is no inference. The
  `RhoFrameworks.Flow.Policy` behaviour dispatches on `:routing` at
  runtime; see `RhoFrameworks.Flow.Policies.Deterministic` (Phase 3) and
  `Hybrid` (Phase 4).
  """

  @type step_type :: :form | :action | :table_review | :fan_out | :select

  @type routing :: :fixed | :auto | :agent_loop

  @type edge_def :: %{
          required(:to) => atom() | :done,
          optional(:guard) => atom() | nil,
          optional(:label) => String.t() | nil
        }

  @type node_def :: %{
          required(:id) => atom(),
          required(:label) => String.t(),
          required(:type) => step_type(),
          required(:next) => atom() | :done | [edge_def()],
          required(:routing) => routing(),
          required(:config) => map(),
          optional(:use_case) => module() | nil,
          optional(:input) => {module(), atom(), list()} | nil
        }

  @callback id() :: String.t()
  @callback label() :: String.t()
  @callback steps() :: [node_def()]

  @doc """
  Optional. Build the input map a node's UseCase will receive.

  Called by `RhoFrameworks.FlowRunner.build_input/3`. If absent, the
  runner passes an empty input.
  """
  @callback build_input(node_id :: atom(), state :: map(), scope :: RhoFrameworks.Scope.t()) ::
              map()

  @optional_callbacks build_input: 3
end
