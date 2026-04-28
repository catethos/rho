class SuggestSkillsOutputSkills {
  name string @description("Short skill name.")
  description string @description("One-sentence description.")
  category string @description("Top-level grouping.")
  cluster string @description("Sub-grouping within the category.")
}

class SuggestSkillsOutput {
  skills SuggestSkillsOutputSkills[]
}

function SuggestSkills(existing: string, intake: string, n: int) -> SuggestSkillsOutput {
  client OpenRouter
  prompt #"
    {{ _.role("system") }}
    You extend an existing skill library. Given the current rows and a
    short intake describing the framework, propose at most `n` *new*
    skills that complement what's there. Reuse existing cluster names
    when the new skill fits. Do not repeat skills that already appear in
    the existing list.
    
    {{ _.role("user") }}
    Framework intake:
    {{intake}}
    
    Existing skills:
    {{existing}}
    
    Return at most {{n}} new skills.
    
    {{ ctx.output_format }}
  "#
}
