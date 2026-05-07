class WriteProficiencyLevelsOutputSkillsLevels {
  level int @description("1-based level index.")
  level_name string @description("Short level title.")
  level_description string @description("1–2 observable sentences.")
}

class WriteProficiencyLevelsOutputSkills {
  levels WriteProficiencyLevelsOutputSkillsLevels[]
  skill_name string @description("Exact skill name from the input.")
  @@stream.done
}

class WriteProficiencyLevelsOutput {
  skills WriteProficiencyLevelsOutputSkills[]
}

function WriteProficiencyLevels(category: string, levels: int, skills: string) -> WriteProficiencyLevelsOutput {
  client OpenRouterOSS120
  prompt #"
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
  "#
}
