defmodule RhoFrameworks.LLM.ScoreLens do
  @moduledoc """
  BAML-backed LLM function for scoring targets against a lens.

  Takes dynamically-built system and user prompts (constructed by the caller
  from the lens definition and target data) and returns structured scores.

  The `work_activities` field is optional — it is populated only when the
  lens targets role profiles (the system prompt instructs the LLM accordingly).

  Replaces the `ReqLLM.generate_object` call chain in `RhoFrameworks.Lenses`.
  """
  use RhoBaml.Function,
    client: "Anthropic",
    params: [system_prompt: :string, user_prompt: :string]

  @schema Zoi.struct(__MODULE__, %{
            variable_scores:
              Zoi.array(
                Zoi.map(%{
                  key: Zoi.string(description: "Variable key matching the lens definition"),
                  score: Zoi.float(description: "Score from 0 to 100"),
                  rationale: Zoi.string(description: "Brief evidence-based rationale")
                }),
                description: "One entry per variable key"
              ),
            work_activities:
              Zoi.array(
                Zoi.map(%{
                  activity: Zoi.string(description: "Description of the work activity"),
                  tag:
                    Zoi.string(
                      description:
                        "One of: automatable, augmentable, human_essential, data_dependent"
                    ),
                  confidence: Zoi.float(description: "Confidence in tag 0.0-1.0")
                }),
                description: "Inferred work activities with AI-readiness tags"
              )
              |> Zoi.optional()
          })

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @type t :: unquote(Zoi.type_spec(@schema))

  @prompt ~S"""
  {{ _.role("system") }}
  {{ system_prompt }}

  {{ _.role("user") }}
  {{ user_prompt }}

  {{ ctx.output_format }}
  """
end
