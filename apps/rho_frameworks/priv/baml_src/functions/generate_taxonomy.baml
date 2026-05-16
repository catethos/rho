class GenerateTaxonomyOutputCategoriesClusters {
  name string @description("Cluster name within the category.")
  description string @description("Cluster scope and boundary.")
  target_skill_count int @description("Suggested number of skills for this cluster.")
  transferability string @description("transferable, role_specific, or mixed.")
  rationale string @description("Why this cluster belongs here.")
  @@stream.done
}

class GenerateTaxonomyOutputCategories {
  name string @description("Top-level category name.")
  description string @description("Category scope and boundary.")
  clusters GenerateTaxonomyOutputCategoriesClusters[]
  rationale string @description("Why this category belongs in the taxonomy.")
  @@stream.done
}

class GenerateTaxonomyOutput {
  name string @description("Framework name.")
  description string @description("One-paragraph framework description.")
  categories GenerateTaxonomyOutputCategories[]
}

function GenerateTaxonomy(name: string, description: string, domain: string, target_roles: string, research: string, seeds: string, source_evidence: string, taxonomy_size: string, category_count: string, clusters_per_category: string, skills_per_cluster: string, strict_counts: string, specificity: string, transferability: string, generation_style: string) -> GenerateTaxonomyOutput {
  client OpenRouterHaiku
  prompt #"
    {{ _.role("system") }}
    You are a competency framework architect. Draft the category -> cluster
    taxonomy first. Do not generate skills.
    
    Rules:
    - Categories must be mutually exclusive and collectively exhaustive for
      the requested framework scope.
    - Clusters must be mutually exclusive within each category.
    - Avoid one category per skill.
    - Avoid generic bucket names like "Other" unless explicitly justified.
    - Respect user counts when strict_counts is true.
    - Treat counts as guidance when strict_counts is false.
    - If specificity=general, avoid niche industry vocabulary.
    - If specificity=industry_specific, include relevant workflows,
      regulatory concepts, and domain vocabulary.
    - If specificity=organization_specific, use supplied organization context
      where present without inventing internal language.
    - If transferability=transferable, prefer reusable capabilities.
    - If transferability=role_specific, prefer role-bound capabilities.
    - If transferability=mixed, label clusters by transferability.
    - Use research/source evidence when supplied.
    
    {{ _.role("user") }}
    Framework name: {{name}}
    Description: {{description}}
    Domain: {{domain}}
    Target roles: {{target_roles}}
    
    Preferences:
    - taxonomy_size: {{taxonomy_size}}
    - category_count: {{category_count}}
    - clusters_per_category: {{clusters_per_category}}
    - skills_per_cluster: {{skills_per_cluster}}
    - strict_counts: {{strict_counts}}
    - specificity: {{specificity}}
    - transferability: {{transferability}}
    - generation_style: {{generation_style}}
    
    Seed examples:
    {{seeds}}
    
    Pinned research:
    {{research}}
    
    Source evidence:
    {{source_evidence}}
    
    {{ ctx.output_format }}
  "#
}
