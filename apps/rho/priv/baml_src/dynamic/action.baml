class Action {
  tool string @description("One of: respond, think, manage_library, save_skeletons, finish")
  message string?
  thought string?
  action string?
  name string?
  description string?
  library_id string?
  library_name string?
  version_tag string?
  notes string?
  skills_json string?
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
