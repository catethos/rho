defmodule RhoFrameworks.LLM.WriteProficiencyLevels do
  @moduledoc """
  BAML-backed structured LLM call that writes Dreyfus-model proficiency
  levels for one category's skills.

  Replaces the per-category `:proficiency_writer` agent loop (Phase 7 of
  `docs/swappable-decision-policy-plan.md`). One streaming call per
  category — partials surface the `skills[]` array as it grows so the
  consumer can persist each fully-formed skill (with all levels filled
  in) as soon as it appears.

  ## Output schema

      %WriteProficiencyLevels{
        skills: [
          %{
            skill_name: String.t,
            levels: [
              %{level: integer, level_name: String.t, level_description: String.t}
            ]
          }
        ]
      }

  The `skill_name` field MUST match an existing skeleton row in the
  caller's library table — `Workbench.set_proficiency/4` matches by
  name. Skills the model invents are skipped silently by the consumer.

  ## Streaming consumer pattern

  Drop a callback into `stream/3` that walks the `skills` array and
  emits each entry exactly once when (a) `skill_name` is non-blank and
  (b) every nested level has `level`, `level_name`, and
  `level_description` populated. See
  `RhoFrameworks.UseCases.GenerateProficiency.default_write/2`.
  """
  use RhoBaml.Function,
    client: "OpenRouterOSS120",
    params: [category: :string, levels: :int, skills: :string]

  @schema Zoi.struct(__MODULE__, %{
            skills:
              Zoi.array(
                Zoi.map(
                  %{
                    skill_name: Zoi.string(description: "Exact skill name from the input."),
                    levels:
                      Zoi.array(
                        Zoi.map(%{
                          level: Zoi.integer(description: "1-based level index."),
                          level_name: Zoi.string(description: "Short level title."),
                          level_description: Zoi.string(description: "1–2 observable sentences.")
                        })
                      )
                  },
                  # @@stream.done — emit each skill atomically. Without this, BAML
                  # streams the in-flight last element with a partial skill_name,
                  # which fails to match an existing skeleton row.
                  metadata: [stream_done: true]
                )
              )
          })

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @type t :: unquote(Zoi.type_spec(@schema))

  @prompt ~S"""
  {{ _.role("system") }}
  You generate Dreyfus-model proficiency levels for competency framework
  skills. You receive a category, the number of levels to generate, and
  a bullet list of skills (each with cluster + description). Produce
  proficiency levels for ONLY the exact skills provided — do not add,
  rename, split, or merge skills. The skills already exist as skeleton
  rows; your output is matched back by `skill_name`.

  ## Dreyfus baseline (adapt count and naming to what was requested)
  - Level 1 — Novice: follows procedures, needs supervision.
  - Level 2 — Advanced Beginner: applies patterns independently.
  - Level 3 — Competent: plans deliberately, owns outcomes.
  - Level 4 — Advanced: exercises judgment, mentors others.
  - Level 5 — Expert: innovates, recognized authority.

  When asked for fewer than 5 levels, select a meaningful subset
  (2 levels: Foundational + Advanced; 3: Foundational + Proficient + Expert).

  ## Quality rules
  - Each `level_description` MUST be observable — what would you literally
    see this person doing? Format: [action verb] + [core activity] +
    [context or outcome].
  - GOOD: "Designs distributed architectures that maintain sub-100ms p99
    latency under 10x traffic spikes."
  - BAD: "Is good at system design."
  - Each level assumes mastery of prior levels — do not repeat lower-level
    behaviours.
  - Levels must be mutually exclusive — if two sound interchangeable,
    rewrite.
  - 1–2 sentences per `level_description`, max.

  {{ _.role("user") }}
  Category: {{category}}
  Levels: {{levels}}

  Skills:
  {{skills}}

  Return one entry per skill above, in the same order. Use the EXACT
  `skill_name` values as given. Generate exactly {{levels}} levels per
  skill.

  {{ ctx.output_format }}
  """
end
