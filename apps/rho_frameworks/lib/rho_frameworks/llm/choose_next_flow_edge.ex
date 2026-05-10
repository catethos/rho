defmodule RhoFrameworks.LLM.ChooseNextFlowEdge do
  @moduledoc """
  BAML-backed router that picks the next flow edge for the Hybrid policy
  on `routing: :auto` nodes.

  Given the current node's label, a numbered list of allowed
  `{edge_id, label}` pairs, and a snapshot of the Workbench summaries,
  returns the chosen `next_edge` (as a string matching one of the
  allowed edge ids), a confidence in 0.0..1.0, and a short reasoning.

  `next_edge` is emitted as a string because `RhoBaml.SchemaCompiler`
  does not encode atoms or enums. The caller (`Flow.Policies.Hybrid`) is
  responsible for validating the returned id against the allowed set
  and converting via `String.to_existing_atom/1`.
  """
  use RhoBaml.Function,
    client: "OpenRouterHaiku",
    params: [current_label: :string, allowed: :string, summary: :string]

  @schema Zoi.struct(__MODULE__, %{
            next_edge:
              Zoi.string(
                description:
                  "The id of the chosen edge — must exactly match one of the allowed edge ids"
              ),
            confidence:
              Zoi.float(description: "Confidence in the choice, 0.0 (low) to 1.0 (high)"),
            reasoning: Zoi.string(description: "One-sentence justification for the choice")
          })

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @type t :: unquote(Zoi.type_spec(@schema))

  @prompt ~S"""
  {{ _.role("system") }}
  You are a flow router. A user is moving through a multi-step workflow,
  and the current step has multiple possible next steps. Your job is to
  pick the single most appropriate next step based on the workflow state.

  Rules:
  - You MUST return next_edge as one of the allowed edge ids verbatim.
  - Prefer the edge whose label best matches the current state.
  - If unsure, prefer the edge that keeps the user moving forward.

  {{ _.role("user") }}
  Current step: {{current_label}}

  Allowed next steps (id — label):
  {{allowed}}

  Workflow state summary:
  {{summary}}

  {{ ctx.output_format }}
  """
end
