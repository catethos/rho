class ScoreLensOutputVariableScores {
  key string @description("Variable key matching the lens definition")
  rationale string @description("Brief evidence-based rationale")
  score float @description("Score from 0 to 100")
}

class ScoreLensOutputWorkActivities {
  tag string @description("One of: automatable, augmentable, human_essential, data_dependent")
  confidence float @description("Confidence in tag 0.0-1.0")
  activity string @description("Description of the work activity")
}

class ScoreLensOutput {
  variable_scores ScoreLensOutputVariableScores[] @description("One entry per variable key")
  work_activities ScoreLensOutputWorkActivities[]? @description("Inferred work activities with AI-readiness tags")
}

function ScoreLens(system_prompt: string, user_prompt: string) -> ScoreLensOutput {
  client Anthropic
  prompt #"
    {{ _.role("system") }}
    {{ system_prompt }}
    
    {{ _.role("user") }}
    {{ user_prompt }}
    
    {{ ctx.output_format }}
  "#
}
