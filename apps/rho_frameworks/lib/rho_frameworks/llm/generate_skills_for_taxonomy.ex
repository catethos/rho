defmodule RhoFrameworks.LLM.GenerateSkillsForTaxonomy do
  @moduledoc """
  BAML-backed structured LLM call that writes skill rows under an approved
  category/cluster taxonomy.
  """

  use RhoBaml.Function,
    client: "OpenRouterHaiku",
    params: [
      name: :string,
      description: :string,
      target_roles: :string,
      research: :string,
      seeds: :string,
      taxonomy: :string,
      existing_skills: :string,
      gaps: :string,
      skills_per_cluster: :string,
      strict_counts: :string
    ]

  @schema Zoi.struct(__MODULE__, %{
            skills:
              Zoi.array(
                Zoi.map(
                  %{
                    category: Zoi.string(description: "Approved category name."),
                    cluster: Zoi.string(description: "Approved cluster name."),
                    name: Zoi.string(description: "Short skill name."),
                    description: Zoi.string(description: "One-sentence description."),
                    cited_findings:
                      Zoi.array(Zoi.integer(),
                        description: "1-based indices into the research bullet list."
                      )
                      |> Zoi.optional()
                  },
                  metadata: [stream_done: true]
                )
              )
          })

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @type t :: unquote(Zoi.type_spec(@schema))

  @prompt ~S"""
  {{ _.role("system") }}
  You are a competency framework architect generating skills under an
  approved taxonomy.

  Rules:
  - Use only categories and clusters from the approved taxonomy.
  - Generate skills under every cluster unless the prompt explicitly marks
    the cluster optional.
  - Do not invent new categories or clusters.
  - Do not collapse clusters.
  - Make skill names concise, 2 to 4 words.
  - Make descriptions observable and domain-appropriate.
  - Avoid duplicates and near duplicates across clusters.
  - If exact counts are not required, prefer coverage quality over count.
  - When research findings are supplied, populate cited_findings with
    1-based indices for derived skills.
  - If existing_skills is non-empty, do not re-emit those skills or
    near-duplicates.
  - If gaps is non-empty, focus on those missing concepts inside the
    approved taxonomy.

  {{ _.role("user") }}
  Framework name: {{name}}
  Description: {{description}}
  Target roles: {{target_roles}}
  Skills per cluster: {{skills_per_cluster}}
  Strict counts: {{strict_counts}}

  Approved taxonomy:
  {{taxonomy}}

  Seed examples:
  {{seeds}}

  Pinned research findings (1-based indices for cited_findings):
  {{research}}

  Existing skills (already present — do NOT regenerate):
  {{existing_skills}}

  Identified gaps:
  {{gaps}}

  {{ ctx.output_format }}
  """
end
