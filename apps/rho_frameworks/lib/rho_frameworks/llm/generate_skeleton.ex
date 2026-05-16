defmodule RhoFrameworks.LLM.GenerateSkeleton do
  @moduledoc """
  BAML-backed structured LLM call that produces the skeleton of a new
  framework: top-level `name` / `description`, plus a list of skills
  grouped by category and cluster.

  Replaces the 3-turn agentic skeleton generator (Phase 6 of
  `docs/swappable-decision-policy-plan.md`). One streaming call, partials
  arrive progressively so rows land in the data table while the model
  is still writing.

  Each skill may include `cited_findings` — 1-based indices into the
  formatted `research:` bullet list passed in the prompt — when research
  context is supplied. Indices let the UI trace generated skills back to
  the research bullets that seeded them. The field is optional; the
  model leaves it empty when no research is supplied.
  """
  use RhoBaml.Function,
    client: "OpenRouterHaiku",
    params: [
      name: :string,
      description: :string,
      target_roles: :string,
      seeds: :string,
      research: :string,
      existing_skills: :string,
      gaps: :string,
      skill_count: :string
    ]

  @schema Zoi.struct(__MODULE__, %{
            name: Zoi.string(description: "Framework name."),
            description: Zoi.string(description: "One-paragraph framework description."),
            skills:
              Zoi.array(
                Zoi.map(
                  %{
                    category: Zoi.string(description: "Top-level grouping."),
                    cluster: Zoi.string(description: "Sub-grouping within the category."),
                    name: Zoi.string(description: "Short skill name."),
                    description: Zoi.string(description: "One-sentence description."),
                    cited_findings:
                      Zoi.array(Zoi.integer(),
                        description: "1-based indices into the research bullet list."
                      )
                      |> Zoi.optional()
                  },
                  # @@stream.done — emit each skill atomically so partials never
                  # contain a half-written skill (e.g. truncated `name`).
                  metadata: [stream_done: true]
                )
              )
          })

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @type t :: unquote(Zoi.type_spec(@schema))

  @prompt ~S"""
  {{ _.role("system") }}
  You are a competency framework architect. Given an intake and any
  available context (similar-role seeds, pinned research findings,
  existing skills already in the framework, identified gaps), produce a
  coherent skeleton: a name, a one-paragraph description, and a flat
  list of skills grouped by category and cluster.

  Rules:
  - This is the legacy quick-generation path. When no taxonomy is supplied,
    infer a compact category/cluster map first, then emit skills under that
    inferred map.
  - Treat the requested skill count as guidance, not a reason to weaken the
    framework structure.
  - Pick a small set of categories and reuse them — do not create one
    category per skill.
  - Each skill name is 2–4 words; the description is one sentence.
  - When research findings are supplied, populate `cited_findings` for
    every skill that derives from one or more findings (1-based indices
    into the research bullet list). Skills that don't derive from a
    finding should leave `cited_findings` empty.
  - If `existing_skills` is non-empty, treat those skills as ALREADY
    covered — do NOT re-emit them or near-duplicates. The user is
    extending the framework, not regenerating it.
  - If `gaps` is non-empty, focus on filling EXACTLY those gaps. Use the
    gap list as your primary guide for what to generate; ignore the
    requested skill count when gaps are specified and emit one skill per
    gap.

  {{ _.role("user") }}
  Framework name: {{name}}
  Description: {{description}}
  Target roles: {{target_roles}}
  Target skill count: {{skill_count}}

  Seed skills from similar roles (inspiration only):
  {{seeds}}

  Pinned research findings (1-based indices for cited_findings):
  {{research}}

  Existing skills (already present — do NOT regenerate):
  {{existing_skills}}

  Identified gaps (fill these when non-empty):
  {{gaps}}

  {{ ctx.output_format }}
  """
end
