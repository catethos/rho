class RankRolesOutput {
  indices int[] @description("1-based indices of the most similar roles from the list, ordered by relevance")
}

function RankRoles(query: string, role_list: string, limit: int) -> RankRolesOutput {
  client OpenRouterHaiku
  prompt #"
    {{ _.role("system") }}
    You are a role matching assistant. Given a query and a numbered list of existing role profiles,
    return the numbers of the most similar roles ordered by relevance.
    Consider semantic similarity — e.g. "Software Engineer" matches "Backend Developer",
    "Full Stack Engineer", etc. Return at most {{limit}} numbers.
    Only return numbers that appear in the list. If nothing is similar, return an empty array.
    
    {{ _.role("user") }}
    Query: {{query}}
    
    Existing roles:
    {{role_list}}
    
    {{ ctx.output_format }}
  "#
}
