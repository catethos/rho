defmodule RhoFrameworks.LLM.SemanticDuplicates do
  @moduledoc """
  BAML-backed verifier for semantically-duplicate skills.

  Per-focal formulation: caller passes one `focal` skill plus a numbered
  list of `candidates` (its top embedding-cosine neighbors). The model
  returns the indices of candidates that name the SAME underlying
  competency as the focal.

  This shape replaces the older flat-pairs format because it (1) avoids
  duplicating each skill's description across many pairs, and (2) gives
  the LLM a single anchor to reason against — empirically improves
  recall on smaller models that otherwise drift conservative.
  """
  use RhoBaml.Function,
    client: "OpenRouter",
    params: [focal: :string, candidates: :string]

  @schema Zoi.struct(__MODULE__, %{
            duplicate_indices:
              Zoi.array(
                Zoi.integer(
                  description: "Index of a candidate confirmed as a duplicate of the focal"
                ),
                description:
                  "Indices (referencing the candidate list) of skills that describe the same underlying competency as the focal"
              )
          })

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @type t :: unquote(Zoi.type_spec(@schema))

  @prompt ~S"""
  {{ _.role("system") }}
  You are a competency framework expert. You judge whether two skill
  descriptions name the SAME underlying competency, despite differences
  in wording, language, or phrasing.

  {{ _.role("user") }}
  Below is a FOCAL skill and a list of CANDIDATES that an embedding
  model flagged as semantically similar to it. For each candidate,
  decide whether it describes the same underlying competency as the
  focal.

  Only include a candidate's index in `duplicate_indices` when you are
  CONFIDENT it is the same competency.

  Do NOT confirm:
    - Subset/superset relationships (e.g. "Marketing" vs "Brand
      Management")
    - Pairs that share a topic but differ in scope or focus (e.g.
      "Data Analysis" exploratory vs "Statistical Analysis"
      hypothesis testing; "Liquidity Management" vs "Cash Flow
      Management")

  DO confirm cross-language or paraphrased pairs that name the exact
  same competency (e.g. "Data Analysis" / "数据分析"; "SQL
  Programming" / "SQL Querying" when both describe query authoring).

  FOCAL:
  {{focal}}

  CANDIDATES:
  {{candidates}}

  Return only the indices of confirmed duplicates. Empty array if none
  of the candidates name the same competency as the focal.

  {{ ctx.output_format }}
  """
end
