class RespondAction {
  tool "respond" @description("Reply directly to the user. The default action — use this whenever no other tool applies. It is the only way to talk to the user, so prefer it for answers, summaries, follow-up questions, and ending a turn after presenting tool results.")
  message string
}

class ThinkAction {
  tool "think" @description("Record an internal reasoning step without external action.")
  thought string
}

class DelegateTaskAction {
  tool "delegate_task" @description("Spawn a sub-agent for a subtask. Use await_task for the result.")
  task string
  role string?
  capability string?
  context_summary string?
  inherit_context bool?
  max_steps int?
}

class DelegateTaskLiteAction {
  tool "delegate_task_lite" @description("Spawn a lightweight agent for single-purpose generation. Use await_all for results.")
  task string
  role string?
  max_steps int?
}

class AwaitTaskAction {
  tool "await_task" @description("Wait for a delegated agent to finish.")
  agent_id string
  timeout int?
}

class AwaitAllAction {
  tool "await_all" @description("Wait for all delegated agents to finish.")
  agent_ids string
  timeout int?
}

class IngestDocumentAction {
  tool "ingest_document" @description("Extract text or table data from an external file (Excel .xlsx, PDF .pdf, Word .docx). Returns the extracted content as text or structured table data. Use the extracted content to populate the spreadsheet with add_rows.")
  file_path string
  format string?
}

class ManageLibraryAction {
  tool "manage_library" @description("Skill library CRUD.")
  action string
  name string?
  description string?
  library_id string?
  library_name string?
  version_tag string?
  notes string?
}

class LoadLibraryAction {
  tool "load_library" @description("Load an EXISTING saved library from the DB into the `library:<name>` working table. Do NOT use after `generate_framework_skeletons` — the skeleton rows are already in the table; `save_framework` is what persists them to the DB. Use only for libraries that have already been saved or for template keys (e.g. sfia_v8).")
  library_name string?
  version string?
  category string?
}

class ForkLibraryAction {
  tool "fork_library" @description("Fork skill library into editable copy.")
  source_library_id string
  new_name string
  categories_json string?
}

class ManageRoleAction {
  tool "manage_role" @description("Role profile CRUD. Actions: list, view, load, save, start_draft, clone.")
  action string
  name string?
  role_profile_id string?
  role_family string?
  seniority_level int?
  seniority_label string?
  description string?
  purpose string?
  resolve_library_id string?
  role_profile_ids_json string?
  mode_label string?
}

class AddProficiencyLevelsAction {
  tool "add_proficiency_levels" @description("Update existing skeleton skills in the data table with proficiency levels. Matches each entry by skill_name to a row already in the table. Skills not found in the table are skipped.")
  levels_json string
  table string?
}

class LoadSimilarRolesAction {
  tool "load_similar_roles" @description("Find existing role profiles similar to the framework being built. Pass intake-style fields; returns the top matches.")
  name string?
  description string?
  domain string?
  target_roles string?
  limit int?
}

class GenerateFrameworkSkeletonsAction {
  tool "generate_framework_skeletons" @description("Generate the skill skeletons for a new framework via a single streaming BAML call. Synchronous (typically 3–5s); rows stream into the session's library:<name> table as partials arrive.")
  name string
  description string
  domain string?
  target_roles string?
  skill_count int?
  similar_role_skills string?
  research string?
}

class GenerateProficiencyAction {
  tool "generate_proficiency" @description("Spawn one proficiency-writer agent per category for the given library table. Reads skeleton rows from the named table and fans out asynchronously.")
  table_name string
  levels int?
}

class SaveFrameworkAction {
  tool "save_framework" @description("Persist the framework currently in the session's library table to the database. If library_id is omitted, saves to (or creates) the org's default library.")
  library_id string?
  table string?
}

class ClarifyAction {
  tool "clarify" @description("Ask the user a clarifying question when the request is genuinely ambiguous. Use only when no reasonable assumption resolves the ambiguity — otherwise call the use-case tool directly. Calling clarify ends your turn.")
  question string
}

class SkillAction {
  tool "skill" @description("Load a skill's workflow instructions by name.")
  name string
}

class UpdateCellsAction {
  tool "update_cells" @description("Update data table cells.")
  changes_json string
  table string?
}

class AddRowsAction {
  tool "add_rows" @description("Add rows to data table.")
  rows_json string
  table string?
}

class DeleteRowsAction {
  tool "delete_rows" @description("Delete data table rows by ID or filter.")
  ids_json string?
  filter_json string?
  table string?
}

function AgentTurn(messages: string) -> RespondAction | ThinkAction | DelegateTaskAction | DelegateTaskLiteAction | AwaitTaskAction | AwaitAllAction | IngestDocumentAction | ManageLibraryAction | LoadLibraryAction | ForkLibraryAction | ManageRoleAction | AddProficiencyLevelsAction | LoadSimilarRolesAction | GenerateFrameworkSkeletonsAction | GenerateProficiencyAction | SaveFrameworkAction | ClarifyAction | SkillAction | UpdateCellsAction | AddRowsAction | DeleteRowsAction {
  client Openrouter
  prompt #"
    {{ messages }}

    {{ ctx.output_format }}
  "#
}
