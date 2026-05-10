defmodule RhoFrameworks.LLM.SummarizeDuplicates do
  @moduledoc """
  BAML-backed cluster summarizer for candidate-duplicate skill pairs.

  Distinct from `RhoFrameworks.LLM.SemanticDuplicates`. That module makes
  per-pair binary judgments (is A == B?) and was retired in the
  2026-04-29 eval — multiple models produced ~75% false positives on
  subset/superset and adjacent-domain pairs.

  This function does a different task: GROUP candidate pairs into themes
  and produce a navigation digest. It never decides the binary "are
  these duplicates" question for any pair — that authority stays with
  the user, who edits the `resolution` cell in the dedup_preview table.

  Caller passes a numbered pair list. Model returns:
    - `clusters`: each with a short label, a list of pair indices that
      belong to it, and a one-line review-strategy hint.
    - `summary_text`: a 1-2 paragraph digest of the overall situation
      (key clusters, suggested review order, expected consolidation).

  Failure modes are bounded: occasional miscluster is acceptable because
  it doesn't change the underlying pair set; the table still shows every
  candidate, the cluster column is just a navigational aid.
  """

  use RhoBaml.Function,
    client: "OpenRouterHaiku",
    params: [pairs: :string, library_context: :string]

  @schema Zoi.struct(__MODULE__, %{
            clusters:
              Zoi.array(
                Zoi.map(%{
                  label: Zoi.string(description: "Short cluster label, 2-5 words."),
                  pair_indices:
                    Zoi.array(
                      Zoi.integer(
                        description: "1-based indices of pairs that belong to this cluster"
                      )
                    ),
                  strategy:
                    Zoi.string(
                      description:
                        "One-line review hint, e.g. 'Likely 2-3 underlying concepts; merge collectively' or 'Distinct domains; likely keep separate'"
                    )
                })
              ),
            summary_text:
              Zoi.string(
                description:
                  "1-2 paragraph digest of the dedup situation: cluster shape, suggested review order, expected consolidation impact"
              )
          })

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @type t :: unquote(Zoi.type_spec(@schema))

  @prompt ~S"""
  {{ _.role("system") }}
  You are a competency framework editor helping a user navigate a list
  of candidate-duplicate skill pairs. Your job is NOT to decide which
  pairs are real duplicates — that decision stays with the user. Your
  job is to give them a structural overview so they can review the list
  efficiently.

  Group pairs by theme (e.g. "risk concepts", "financial analysis
  variants", "compliance domains"). For each cluster, give a one-line
  hint about how to approach review:
    - "Likely N underlying concepts; merge collectively" — when pairs
      look like surface variants of the same competencies
    - "Distinct domains; likely keep separate" — when pairs share
      vocabulary but belong to different practice areas
    - "Mixed: some merge candidates, some keep" — when judgement is
      genuinely needed

  Then write a short digest (1-2 paragraphs) suggesting which clusters
  to review first based on consolidation impact (clusters with many
  near-identical pairs first; clusters likely to be all-keep last).

  Do NOT call any pair a duplicate. Do NOT recommend specific merges.
  Cluster + strategy + digest only.

  {{ _.role("user") }}
  Library context:
  {{library_context}}

  Candidate duplicate pairs (numbered, 1-indexed):
  {{pairs}}

  {{ ctx.output_format }}
  """
end
