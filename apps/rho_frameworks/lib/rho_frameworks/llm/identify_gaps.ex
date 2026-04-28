defmodule RhoFrameworks.LLM.IdentifyGaps do
  @moduledoc """
  BAML-backed structured LLM call that surfaces missing skills in an
  existing framework, given the new framework's intake (description,
  domain, target roles).

  Returns a flat list of gap entries, each with the proposed skill name,
  category, and a one-sentence rationale tying it back to the intake.
  Cheap call — the heavy input is the `existing_skills` rendering, the
  output stays small.
  """
  use RhoBaml.Function,
    client: "OpenRouter",
    params: [
      framework_name: :string,
      framework_description: :string,
      domain: :string,
      target_roles: :string,
      existing_skills: :string
    ]

  @schema Zoi.struct(__MODULE__, %{
            gaps:
              Zoi.array(
                Zoi.map(%{
                  skill_name: Zoi.string(description: "Short skill name (2–4 words)."),
                  category: Zoi.string(description: "Top-level grouping for the new skill."),
                  rationale:
                    Zoi.string(description: "One sentence explaining why this skill is missing.")
                })
              )
          })

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @type t :: unquote(Zoi.type_spec(@schema))

  @prompt ~S"""
  {{ _.role("system") }}
  You are a competency framework architect. Given an existing framework's
  skills and the intake describing how the user wants to extend it,
  identify the skills that are MISSING relative to the intake. Do not
  re-list skills already present. Each gap is a concrete skill the
  extended framework should add.

  Rules:
  - Pick categories that already exist in the framework when they fit;
    only invent a new category when the gap doesn't belong anywhere.
  - 2–8 gaps total. Quality over coverage — leave the list short if
    the existing framework already covers the intake well.
  - One sentence rationale per gap, citing the intake (target roles or
    description) when possible.

  {{ _.role("user") }}
  Framework name: {{framework_name}}
  Framework description: {{framework_description}}
  Domain: {{domain}}
  Target roles: {{target_roles}}

  Existing skills:
  {{existing_skills}}

  {{ ctx.output_format }}
  """
end
