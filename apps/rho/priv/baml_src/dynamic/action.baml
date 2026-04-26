class Action {
  tool string @description("One of: respond, think, present_ui, skill, create_anchor, search_history, recall_context, clear_memory, delegate_task, delegate_task_lite, await_task, await_all, spawn_agent, stop_agent, send_message, broadcast_message, list_agents, find_capable, get_agent_card, finish")
  message string?
  thought string?
  spec string?
  title string?
  name string?
  summary string?
  next_steps string[]?
  query string?
  limit int?
  phase string?
  archive bool?
  confirm bool?
  task string?
  role string?
  capability string?
  context_summary string?
  inherit_context bool?
  max_steps int?
  agent_id string?
  timeout int?
  agent_ids string?
  system_prompt_extra string?
  target string?
  result string?
  thinking string?
}

function AgentTurn(messages: string) -> Action {
  client Openrouter
  prompt #"
    {{ messages }}

    {{ ctx.output_format }}
  "#
}
