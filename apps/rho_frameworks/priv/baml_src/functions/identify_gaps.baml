class IdentifyGapsOutputGaps {
  category string @description("Top-level grouping for the new skill.")
  skill_name string @description("Short skill name (2–4 words).")
  rationale string @description("One sentence explaining why this skill is missing.")
}

class IdentifyGapsOutput {
  gaps IdentifyGapsOutputGaps[]
}

function IdentifyGaps(framework_name: string, framework_description: string, domain: string, target_roles: string, existing_skills: string) -> IdentifyGapsOutput {
  client OpenRouter
  prompt #"
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
  "#
}
