defmodule RhoFrameworks.LLM.SuggestSkills do
  @moduledoc """
  BAML-backed structured LLM call that proposes additional skills for an
  existing library. Powers the "Suggest" toolbar button (§11.3 Direct →
  escalate-once in `docs/swappable-decision-policy-plan.md`).

  Inputs:

    * `existing` — bullet-list rendering of the current library rows so
      the model knows what to extend (and what to avoid duplicating).
    * `intake` — short framework context (name + description) read from
      the session's `meta` table. May be empty.
    * `n` — how many new skills to suggest, capped by the caller.

  Returned schema is a flat list of
  `%Skill{category, cluster, name, description}` so rows can land in the
  strict `library` table without a follow-up cleanup step. Streaming
  partials surface the array as it grows; the consumer is responsible
  for filtering for fully-formed entries (all four fields present and
  non-empty) before persisting.
  """
  use RhoBaml.Function,
    client: "OpenRouter",
    params: [existing: :string, intake: :string, n: :int]

  @schema Zoi.struct(__MODULE__, %{
            skills:
              Zoi.array(
                Zoi.map(%{
                  category: Zoi.string(description: "Top-level grouping."),
                  cluster: Zoi.string(description: "Sub-grouping within the category."),
                  name: Zoi.string(description: "Short skill name."),
                  description: Zoi.string(description: "One-sentence description.")
                })
              )
          })

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @type t :: unquote(Zoi.type_spec(@schema))

  @prompt ~S"""
  {{ _.role("system") }}
  You extend an existing skill library. Given the current rows and a
  short intake describing the framework, propose at most `n` *new*
  skills that complement what's there. Reuse existing cluster names
  when the new skill fits. Do not repeat skills that already appear in
  the existing list.

  {{ _.role("user") }}
  Framework intake:
  {{intake}}

  Existing skills:
  {{existing}}

  Return at most {{n}} new skills.

  {{ ctx.output_format }}
  """
end
