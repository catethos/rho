defmodule RhoFrameworks.LLM.SemanticDuplicates do
  @moduledoc """
  BAML-backed LLM function for finding semantically duplicate skills.

  Given a formatted list of skills (with IDs in brackets), returns pairs
  of skills that describe the same underlying competency.

  Replaces the LiteWorker-based `find_semantic_duplicates_via_llm` in
  `RhoFrameworks.Library` with a direct structured LLM call.
  """
  use RhoBaml.Function,
    client: "OpenRouter",
    params: [skill_list: :string]

  @schema Zoi.struct(__MODULE__, %{
            pairs:
              Zoi.array(
                Zoi.map(%{
                  id_a: Zoi.integer(description: "ID of first skill"),
                  id_b: Zoi.integer(description: "ID of second skill")
                }),
                description: "Pairs of semantically duplicate skills"
              )
          })

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @type t :: unquote(Zoi.type_spec(@schema))

  @prompt ~S"""
  {{ _.role("system") }}
  You are a competency framework expert that identifies semantically duplicate skills.

  {{ _.role("user") }}
  Below is a list of skills from a single competency library.
  Identify pairs that are semantically the same competency despite different names.

  Only flag pairs where you are confident they describe the same underlying skill.
  Do NOT flag pairs that are related but distinct (e.g., "Data Analysis" and "Statistical Analysis"
  are different if one focuses on exploratory work and the other on hypothesis testing).

  Skills:
  {{skill_list}}

  If no semantic duplicates are found, return an empty pairs array.

  {{ ctx.output_format }}
  """
end
