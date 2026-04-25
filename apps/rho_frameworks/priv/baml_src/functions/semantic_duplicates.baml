class SemanticDuplicatesOutputPairs {
  id_a int @description("ID of first skill")
  id_b int @description("ID of second skill")
}

class SemanticDuplicatesOutput {
  pairs SemanticDuplicatesOutputPairs[] @description("Pairs of semantically duplicate skills")
}

function SemanticDuplicates(skill_list: string) -> SemanticDuplicatesOutput {
  client OpenRouter
  prompt #"
    {{ _.role("system") }}
    You are a competency framework expert that identifies semantically duplicate skills.
    
    {{ _.role("user") }}
    Below is a list of skills from a single competency library.
    Identify pairs that are semantically the same competency despite different names.
    
    Only flag pairs where you are confident they describe the same underlying skill.
    Do NOT flag pairs that are related but distinct (e.g., "Data Analysis" and "Statistical Analysis"
    are different if one focuses on exploratory work and the other on hypothesis testing).
    
    Skills:
    {{skill_list}}
    
    If no semantic duplicates are found, return an empty pairs array.
    
    {{ ctx.output_format }}
  "#
}
