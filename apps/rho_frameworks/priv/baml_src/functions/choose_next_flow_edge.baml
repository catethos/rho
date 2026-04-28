class ChooseNextFlowEdgeOutput {
  confidence float @description("Confidence in the choice, 0.0 (low) to 1.0 (high)")
  next_edge string @description("The id of the chosen edge — must exactly match one of the allowed edge ids")
  reasoning string @description("One-sentence justification for the choice")
}

function ChooseNextFlowEdge(current_label: string, allowed: string, summary: string) -> ChooseNextFlowEdgeOutput {
  client OpenRouter
  prompt #"
    {{ _.role("system") }}
    You are a flow router. A user is moving through a multi-step workflow,
    and the current step has multiple possible next steps. Your job is to
    pick the single most appropriate next step based on the workflow state.
    
    Rules:
    - You MUST return next_edge as one of the allowed edge ids verbatim.
    - Prefer the edge whose label best matches the current state.
    - If unsure, prefer the edge that keeps the user moving forward.
    
    {{ _.role("user") }}
    Current step: {{current_label}}
    
    Allowed next steps (id — label):
    {{allowed}}
    
    Workflow state summary:
    {{summary}}
    
    {{ ctx.output_format }}
  "#
}
