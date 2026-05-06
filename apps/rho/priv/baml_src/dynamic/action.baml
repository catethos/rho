class RespondAction {
  tool "respond" @description("Reply directly to the user. The ONLY way to send text to the user — use it for answers, summaries, follow-up questions, error reports, and clarification requests. When you are missing information, blocked, or uncertain, ALWAYS use respond (set kind to question, error, or clarification) instead of free-text — never write user-facing prose outside this action.")
  message string
  kind string?
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

class AwaitTaskAction {
  tool "await_task" @description("Wait for a delegated agent to finish.")
  agent_id string
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

class SkillAction {
  tool "skill" @description("Load a skill's workflow instructions by name.")
  name string
}

class QueryTableAction {
  tool "query_table" @description("Read data table rows. Pass `ids_json` (a JSON array of row IDs copied from the prompt's Selected block) to fetch exactly those rows — preferred when acting on the user's selection. Otherwise use filter_field/filter_value for equality search, or no filter to read the whole table (subject to limit).")
  table string?
  ids_json string?
  columns string?
  filter_field string?
  filter_value string?
  limit string?
  offset string?
}

class UpdateCellsAction {
  tool "update_cells" @description("Update data table cells. Each change is a JSON object: {\"id\": \"<row_id>\", \"field\": \"<col>\", \"value\": <new>} for a top-level cell, or {\"id\": \"<row_id>\", \"child_key\": {\"<key>\": <val>}, \"field\": \"<child_col>\", \"value\": <new>} for a nested child (a row in the parent's children list, addressed by natural key — e.g. child_key={\"level\": 3}). Field names must match the schema; unknown fields error.")
  changes_json string
  table string?
}

class EditRowAction {
  tool "edit_row" @description("Edit one row by a natural locator. Prefer the flat string params (match_field/match_value, set_field/set_value) — they avoid JSON encoding entirely. Use match_json/set_json only for multi-field locators or updates. To edit a nested child cell (e.g. one proficiency level), add child_match_field + child_match_value (or child_match_json); set_field/set_value then apply to that child. Errors if 0 or >1 rows or children match.")
  table string?
  match_field string?
  match_value string?
  set_field string?
  set_value string?
  match_json string?
  set_json string?
  child_match_field string?
  child_match_value string?
  child_match_json string?
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

function AgentTurn(messages: string) -> RespondAction | ThinkAction | DelegateTaskAction | AwaitTaskAction | IngestDocumentAction | ManageLibraryAction | LoadLibraryAction | ForkLibraryAction | ManageRoleAction | LoadSimilarRolesAction | GenerateFrameworkSkeletonsAction | GenerateProficiencyAction | SaveFrameworkAction | SkillAction | QueryTableAction | UpdateCellsAction | EditRowAction | AddRowsAction | DeleteRowsAction {
  client Openrouter
  prompt #"
    {{ messages }}

    {{ ctx.output_format }}

    Reply with exactly one JSON object matching one of the schemas above.
    It must include the "tool" discriminator field. Do not write any prose,
    commentary, or explanation outside the JSON object — if you need to
    speak to the user, use the "respond" action and put the text in its
    "message" field.
  "#
}
