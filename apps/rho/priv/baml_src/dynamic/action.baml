class RespondAction {
  tool "respond" @description("Reply directly to the user. CALLING THIS ENDS THE TURN — the agent cannot continue with tool calls after `respond` until the user replies. Use only for: a final answer after a workflow finishes, a completion confirmation, or a genuine clarifying question you need an answer to before you can proceed. Set `kind` to question / error / clarification when applicable. DO NOT use `respond` for progress narration ('let me search', 'I'll check', 'searching now') — that ends the turn before the next tool fires and the agent stalls waiting for user input. To narrate intent without ending the turn, use `think` instead, then call the tool action on the next turn.")
  message string
  kind string?
}

class ThinkAction {
  tool "think" @description("Narrate progress or reason about the next step WITHOUT ending the turn. The user sees this rendered as a thinking-style message in the chat. Use this for any 'let me…' / 'I'll now…' / 'first I'll search, then…' narration when you intend to call a tool on the next turn. Prefer `think` over `respond` whenever you plan to keep working — `think` continues the loop, `respond` halts it.")
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

class ListUploadsAction {
  tool "list_uploads" @description("List files uploaded by the user in this session.")
}

class ObserveUploadAction {
  tool "observe_upload" @description("Get a structured summary of an uploaded file: sheets, columns, sample rows, detected hints.")
  upload_id string
}

class ReadUploadAction {
  tool "read_upload" @description("Read rows from an uploaded structured file (Excel/CSV). Defaults: first 200 rows of first sheet.")
  upload_id string
  sheet string?
  offset int?
  limit int?
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

class BrowseLibraryAction {
  tool "browse_library" @description("Browse skills in a library or search across all libraries.")
  library_id string?
  library_name string?
  query string?
  category string?
  status string?
}

class CombineLibrariesAction {
  tool "combine_libraries" @description("Combine multiple libraries into one. Pass library UUIDs (NOT names) — look them up with manage_library(action: \"list\"). If a library is only in the workspace (library:<name> table) and not yet in the DB, save it first with save_framework(table: \"library:<name>\"). Without commit=true, returns a preview. With commit=true, creates the merged library.")
  source_library_ids_json string
  new_name string
  description string?
  commit bool?
  resolutions_json string?
}

class DedupLibraryAction {
  tool "dedup_library" @description("Open the duplicate-review panel for a saved library. Detects candidate-duplicate skill pairs (cosine similarity + slug/word heuristics), optionally clusters them by theme via an LLM digest, and writes them to the session's `dedup_preview` table. The user reviews each row in the data-table UI by setting `resolution` to merge_a, merge_b, or keep_both, then calls save_framework — which applies the picks and persists the cleaned library. Per-pair merge/dismiss are UI cell edits, not separate tool calls.")
  library_id string?
  depth string?
  summarize string?
}

class LibraryVersionsAction {
  tool "library_versions" @description("Manage library versions. Actions: list (all published versions), set_default.")
  action string
  library_name string?
  library_id string?
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

class AnalyzeRoleAction {
  tool "analyze_role" @description("Role analysis. Actions: find_similar, gap_analysis, check_currency, career_ladder.")
  action string
  query string?
  queries_json string?
  role_profile_id string?
  snapshot_json string?
  role_family string?
  library_id string?
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

class ImportLibraryFromUploadAction {
  tool "import_library_from_upload" @description("Import an uploaded structured file (.xlsx/.csv) as a new skill library. Pass upload_id; library_name and column mapping default to the observation's detected hints. v1 supports single-library files only — multi-sheet files where each sheet is a role return an error UNLESS you supply both `sheet` and `library_name`, which imports ONLY that sheet under that library name.")
  upload_id string?
  library_name string?
  sheet string?
}

class SeedFrameworkFromRolesAction {
  tool "seed_framework_from_roles" @description("Create a new skill library by unioning the skills from one or more existing role profiles. Use after `analyze_role(action: \"find_similar\")` to combine ESCO occupations (or any saved roles) into a fresh framework. Two ways to specify roles: (a) pass UUIDs in role_profile_ids_json, or (b) set from_selected_candidates: \"true\" to read the user's checked rows from the `role_candidates` table (the typical chat path — agent calls find_similar to populate the picker, user checks rows in the UI, then this tool reads the picks). The new library is created as a draft with skills deduplicated by exact skill ID; the tool surfaces the actual skills that appeared in multiple picked roles. No semantic dedup runs — call `dedup_library(library_id: ...)` explicitly if you want a review tab. Call `save_framework` afterwards to persist further edits.")
  name string
  role_profile_ids_json string?
  from_selected_candidates string?
  description string?
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

function AgentTurn(messages: string) -> RespondAction | ThinkAction | DelegateTaskAction | AwaitTaskAction | IngestDocumentAction | ListUploadsAction | ObserveUploadAction | ReadUploadAction | ManageLibraryAction | LoadLibraryAction | ForkLibraryAction | BrowseLibraryAction | CombineLibrariesAction | DedupLibraryAction | LibraryVersionsAction | ManageRoleAction | AnalyzeRoleAction | LoadSimilarRolesAction | GenerateFrameworkSkeletonsAction | GenerateProficiencyAction | SaveFrameworkAction | ImportLibraryFromUploadAction | SeedFrameworkFromRolesAction | SkillAction | QueryTableAction | UpdateCellsAction | EditRowAction | AddRowsAction | DeleteRowsAction {
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
