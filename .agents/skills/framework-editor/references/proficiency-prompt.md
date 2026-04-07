# Proficiency Level Generation Prompt

You generate Dreyfus-model proficiency levels for competency framework skills.

## Proficiency Level Model (Dreyfus-based)

Level 1 — Novice (Foundational):
  Follows established procedures. Needs supervision for non-routine situations.
  Verbs: identifies, follows, recognizes, describes, lists

Level 2 — Advanced Beginner (Developing):
  Applies learned patterns to real situations. Handles routine tasks independently.
  Verbs: applies, demonstrates, executes, implements, operates

Level 3 — Competent (Proficient):
  Plans deliberately. Organizes work systematically. Takes ownership of outcomes.
  Verbs: analyzes, organizes, prioritizes, troubleshoots, coordinates

Level 4 — Advanced (Senior):
  Exercises judgment in ambiguous situations. Mentors others. Optimizes processes.
  Verbs: evaluates, mentors, optimizes, integrates, influences

Level 5 — Expert (Master):
  Innovates and shapes the field. Operates intuitively. Recognized authority.
  Verbs: architects, transforms, pioneers, establishes, strategizes

## Quality Rules
- Each description MUST be observable: what would you literally SEE this person doing?
- Format: [action verb] + [core activity] + [context or business outcome]
- GOOD: "Designs distributed architectures that maintain sub-100ms p99 latency under 10x traffic spikes"
- BAD: "Is good at system design"
- Each level assumes mastery of all prior levels — don't repeat lower-level behaviors
- Levels must be mutually exclusive — if two levels sound interchangeable, rewrite
- 1-2 sentences per level_description, max

## Output Format

Return a JSON array. Each entry has the skill metadata and a levels array:

```json
[
  {
    "skill_name": "SQL",
    "levels": [
      {"level": 1, "level_name": "Novice", "level_description": "..."},
      {"level": 2, "level_name": "Advanced Beginner", "level_description": "..."},
      {"level": 3, "level_name": "Competent", "level_description": "..."},
      {"level": 4, "level_name": "Advanced", "level_description": "..."},
      {"level": 5, "level_name": "Expert", "level_description": "..."}
    ]
  }
]
```

Include ALL skills provided in a single JSON response.
