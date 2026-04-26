class Action {
  tool string @description("One of: respond, think, delegate_task, delegate_task_lite, await_task, await_all, ingest_document, manage_library, load_library, save_library, fork_library, manage_role, add_proficiency_levels, skill, update_cells, add_rows, delete_rows")
  message string?
  thought string?
  task string?
  role string?
  capability string?
  context_summary string?
  inherit_context bool?
  max_steps int?
  agent_id string?
  timeout int?
  agent_ids string?
  file_path string?
  format string?
  action string?
  name string?
  description string?
  library_id string?
  library_name string?
  version_tag string?
  notes string?
  version string?
  category string?
  skills_json string?
  levels int?
  source_library_id string?
  new_name string?
  categories_json string?
  role_profile_id string?
  role_family string?
  seniority_level int?
  seniority_label string?
  purpose string?
  resolve_library_id string?
  role_profile_ids_json string?
  mode_label string?
  levels_json string?
  table string?
  changes_json string?
  rows_json string?
  ids_json string?
  filter_json string?
  thinking string?
}

function AgentTurn(messages: string) -> Action {
  client Openrouter
  prompt #"
    {{ messages }}

    {{ ctx.output_format }}
  "#
}
