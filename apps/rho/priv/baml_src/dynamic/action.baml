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
  tool "ingest_document" @description("Extract table data from Excel/CSV or lightweight text from TXT/MD/HTML files. PDF/DOCX inputs return stored-only summaries. Use the extracted content to populate the spreadsheet with add_rows.")
  file_path string
  format string?
}

class ListUploadsAction {
  tool "list_uploads" @description("List files uploaded by the user in this session.")
}

class ObserveUploadAction {
  tool "observe_upload" @description("Get a summary of an uploaded file. Structured files include sheets, columns, sample rows, and detected hints.")
  upload_id string
}

class ReadUploadAction {
  tool "read_upload" @description("Read rows from an uploaded structured file (Excel/CSV). Defaults: first 200 rows of first sheet.")
  upload_id string
  sheet string?
  offset int?
  limit int?
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

function AgentTurn(messages: string) -> RespondAction | ThinkAction | DelegateTaskAction | AwaitTaskAction | IngestDocumentAction | ListUploadsAction | ObserveUploadAction | ReadUploadAction | SkillAction | QueryTableAction | UpdateCellsAction | EditRowAction | AddRowsAction | DeleteRowsAction {
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
