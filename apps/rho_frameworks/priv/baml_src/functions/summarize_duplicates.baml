class SummarizeDuplicatesOutputClusters {
  label string @description("Short cluster label, 2-5 words.")
  strategy string @description("One-line review hint, e.g. 'Likely 2-3 underlying concepts; merge collectively' or 'Distinct domains; likely keep separate'")
  pair_indices int[]
}

class SummarizeDuplicatesOutput {
  summary_text string @description("1-2 paragraph digest of the dedup situation: cluster shape, suggested review order, expected consolidation impact")
  clusters SummarizeDuplicatesOutputClusters[]
}

function SummarizeDuplicates(pairs: string, library_context: string) -> SummarizeDuplicatesOutput {
  client OpenRouterHaiku
  prompt #"
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
  "#
}
