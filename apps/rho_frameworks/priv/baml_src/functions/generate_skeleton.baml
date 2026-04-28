class GenerateSkeletonOutputSkills {
  name string @description("Short skill name.")
  description string @description("One-sentence description.")
  category string @description("Top-level grouping.")
  cluster string @description("Sub-grouping within the category.")
  cited_findings int[]? @description("1-based indices into the research bullet list.")
  @@stream.done
}

class GenerateSkeletonOutput {
  name string @description("Framework name.")
  description string @description("One-paragraph framework description.")
  skills GenerateSkeletonOutputSkills[]
}

function GenerateSkeleton(name: string, description: string, target_roles: string, seeds: string, research: string, existing_skills: string, gaps: string, skill_count: string) -> GenerateSkeletonOutput {
  client OpenRouter
  prompt #"
    {{ _.role("system") }}
    You are a competency framework architect. Given an intake and any
    available context (similar-role seeds, pinned research findings,
    existing skills already in the framework, identified gaps), produce a
    coherent skeleton: a name, a one-paragraph description, and a flat
    list of skills grouped by category and cluster.
    
    Rules:
    - Aim for the requested skill count (give or take a few).
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
  "#
}
