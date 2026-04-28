defmodule RhoFrameworks.UseCase do
  @moduledoc """
  Behaviour for orchestrated work units that mutate the framework.

  UseCases are **commands**: they don't compute and return a framework,
  they mutate the Workbench (via `RhoFrameworks.Workbench`) and return a
  small status payload. Anything a caller wants to "see" from the
  framework is read from the Workbench / DataTable.

  Two consumers, one home: a `RhoFrameworks.Flows.*` flow node references
  a UseCase, and `RhoFrameworks.Tools.WorkflowTools` exposes the same
  UseCase as a ReqLLM tool for the chat agent.

  `describe/0` is required — `cost_hint` powers UI badges and the chat
  tool wrapper needs `label`/`doc` for prompt generation. `cost_hint` is
  UI-only — the deterministic-vs-agentic dispatch decision lives on the
  flow node's `:routing` value, not here.
  """

  alias RhoFrameworks.Scope

  @type cost_hint :: :instant | :cheap | :agent

  @type result ::
          :ok
          | {:ok, summary :: map()}
          | {:async, summary :: map()}
          | {:error, term()}

  @type description :: %{
          required(:id) => atom(),
          required(:label) => String.t(),
          required(:cost_hint) => cost_hint(),
          optional(:input_schema) => module(),
          optional(:output_schema) => module(),
          optional(:doc) => String.t()
        }

  @callback run(input :: map(), Scope.t()) :: result()
  @callback describe() :: description()
end
