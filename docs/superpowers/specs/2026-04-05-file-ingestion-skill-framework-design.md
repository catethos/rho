# File Ingestion for Skill Framework Editor — Design Spec

## Problem

The spreadsheet-based skill framework editor currently only supports generating frameworks from scratch via text conversation. Solution consultants report that clients frequently bring **existing frameworks** in various file formats (Excel, CSV, PDF, images) and expect:

1. **100% faithful import** of structured files (Excel/CSV)
2. **AI interpretation** of unstructured files (prose PDFs, whiteboard photos)
3. **Reference-based generation** — using an uploaded file as context for a new framework
4. **Multi-file upload** — multiple files of mixed types in a single message
5. **Upload at any point** in the conversation, not just at the start

The current architecture has no file upload support in `SpreadsheetLive`, no file parsing pipeline, and a monolithic system prompt that would become unmanageable with additional workflows.

## Design Goals

1. **One skill, internal routing** — a single `framework-editor` SKILL.md that acts as a router, dispatching to reference files based on user intent
2. **Deterministic extraction for structured files** — Excel/CSV parsing via Python scripts in the backend, no LLM involved
3. **AI interpretation for unstructured files** — prose PDFs and images go through the LLM
4. **Progressive disclosure** — summary in message, full data via tool (context-efficient)
5. **Minimal Rho core changes** — extend existing mount/skill system, don't restructure it
6. **Follows agentskills.io spec** — standard SKILL.md + references/ + scripts/ layout

## Architecture Overview

### Three-Plane View

```
EDGE PLANE (SpreadsheetLive)
  ├── Multi-file upload (allow_upload)
  ├── File parsing on upload (Rho.FileParser)
  ├── Parse results stored in assigns
  └── Summary injected into user message

EXECUTION PLANE (Agent + Mounts)
  ├── Rho.Skills mount → discovers framework-editor skill
  ├── Rho.Mounts.Spreadsheet → existing CRUD tools (unchanged)
  ├── read_resource tool → loads reference workflow files on demand
  ├── get_uploaded_file tool → reads parsed file data on demand
  └── Multi-agent delegation → parallel proficiency generation (unchanged)

SKILL LAYER (.agents/skills/framework-editor/)
  ├── SKILL.md → intent router (~200 lines)
  ├── references/ → workflow files loaded on demand
  └── scripts/ → Python parsers called by backend FileParser
```

### Skill Directory Layout

```
.agents/skills/framework-editor/          # Skill (agent-facing)
├── SKILL.md                              # Router: intent detection + dispatch
└── references/
    ├── generate-workflow.md              # Phase 1-3: intake → skeleton → proficiency
    ├── import-workflow.md                # Structured file → spreadsheet mapping
    ├── enhance-workflow.md               # AI enhancement of imported data
    ├── reference-workflow.md             # Using file as context for new generation
    ├── dreyfus-model.md                  # Proficiency level definitions
    ├── blooms-verbs.md                   # Action verbs per cognitive level
    ├── quality-rubric.md                 # Observable behavior quality rules
    └── column-mapping.md                 # Common column name aliases + mapping protocol

priv/python/file_parser/                  # Backend Python scripts (owned by FileParser module)
├── parse_excel.py                        # openpyxl + chardet: .xlsx/.csv → JSON
├── parse_pdf.py                          # pdfplumber: table extraction + text fallback
└── detect_structure.py                   # Classify: structured table or prose?
```

### Key Design Decision: Scripts Run in Backend, Not Agent

The spreadsheet agent does NOT mount `:bash` or `:python` — it can't execute scripts directly. The `scripts/` directory is consumed by `Rho.FileParser` (a backend Elixir module) at upload time, before the agent ever sees the file. This is intentional: file parsing should be deterministic and fast, not dependent on LLM reasoning.

```
User uploads file
  → SpreadsheetLive.consume_uploaded_entries()
  → Rho.FileParser.parse(path, mime_type)
    → routes to scripts/parse_excel.py (via Pythonx) for .xlsx/.csv
    → routes to scripts/parse_pdf.py (via Pythonx) for .pdf
    → base64 encode for images
  → Parse result stored in socket assigns
  → Summary injected into user message to agent
  → Agent uses get_uploaded_file tool to read full data when needed
```

## Component Specifications

### 1. SKILL.md — The Router

```yaml
---
name: framework-editor
description: >
  Build, import, enhance, and manage competency/skill frameworks.
  Activate when the user wants to: create a new framework from scratch,
  import an existing framework from Excel/CSV/PDF/image files,
  enhance an imported framework with AI-generated proficiency levels,
  or use an uploaded file as reference for a new framework.
---
```

The body contains an **intent detection table** that maps user signals to reference files:

| Signal | Intent | Action |
|--------|--------|--------|
| No files, describes a role/domain | Generate | Load `references/generate-workflow.md` |
| Uploads Excel/CSV + "import"/"load"/"use this" | Import | Load `references/import-workflow.md` |
| Uploads file + "improve"/"add levels"/"enhance" | Enhance | Load `import-workflow.md` then `enhance-workflow.md` |
| Uploads file + "like this"/"similar to"/"based on" | Reference | Load `references/reference-workflow.md` |
| Already has data + edit request | Edit | Use spreadsheet tools directly (no workflow file) |
| Ambiguous | Ask | "Would you like me to import this, or use it as a reference?" |

The SKILL.md also includes shared rules that always apply (MECE categories, Dreyfus default, 6-10 competencies per role, observable behavioral indicators).

### 2. Rho.FileParser (New Module)

**File:** `lib/rho/file_parser.ex`

Elixir module that routes file parsing by MIME type. Calls Python code via `Pythonx.eval/2` directly (not through the agent's Python interpreter — `FileParser` is a backend module, not a mount).

**Script ownership:** `FileParser` owns its Python code as module attributes (inline strings) or reads from `priv/python/file_parser/`. The `.agents/skills/framework-editor/scripts/` directory is a documentation convention showing what the skill depends on, but the actual parsing code lives in the Elixir app's `priv/` to avoid coupling a backend module to skill discovery paths.

**Python dependencies:** Add to `.rho.exs` spreadsheet agent config:

```elixir
python_deps: ["openpyxl", "pdfplumber", "chardet"]
```

These get picked up by `Rho.Config.python_deps/0` and installed via `Pythonx.uv_init/1` at app startup. `chardet` is needed for CSV/Excel encoding detection (Asian clients may use GB2312, Big5, Shift-JIS).

**CSV handling:** `parse_excel.py` must:
- Auto-detect encoding via `chardet.detect()` before reading
- Auto-detect delimiter via `csv.Sniffer().sniff()` (handles comma, semicolon, tab)
- Fall back to UTF-8 + comma if detection fails

```elixir
@spec parse(path :: String.t(), mime_type :: String.t()) ::
  {:structured, %{sheets: [%{name: String.t(), rows: [map()], columns: [String.t()], row_count: integer()}]}}
  | {:text, String.t()}
  | {:image, binary(), String.t()}
  | {:error, String.t()}
```

For single-sheet files (CSV, single-sheet Excel), `sheets` still returns a list with one element for consistency.

**Routing:**

| MIME Type | Handler | Output |
|-----------|---------|--------|
| `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` (.xlsx) | `scripts/parse_excel.py` via Pythonx | `{:structured, %{rows, columns, row_count}}` |
| `text/csv` | `scripts/parse_excel.py` via Pythonx (handles both) | `{:structured, %{sheets: [%{name, rows, columns, row_count}]}}` |
| `application/pdf` | `scripts/parse_pdf.py` via Pythonx | `{:structured, ...}` or `{:text, content}` |
| `image/*` | `File.read!` + Base64 | `{:image, base64_data, media_type}` |
| Other | — | `{:error, "Unsupported file type: .xls. Please re-save as .xlsx"}` |

**Multi-sheet Excel handling:** `parse_excel.py` reads ALL sheets from an Excel file and returns them as a list: `{sheets: [{name: "Tech Skills", rows: [...], columns: [...]}, ...]}`. The file summary tells the agent about each sheet (name + row count). If there's only one sheet, the agent proceeds directly. If multiple sheets, the agent asks the user which sheet(s) to import.

**PDF two-pass strategy** (in `parse_pdf.py`):
1. Try pdfplumber table extraction
2. If tables found with >3 columns and >5 rows → `{:structured, ...}`
3. If no clean tables → extract text → `{:text, content}`
4. Scanned PDFs (no extractable text) → `{:error, "Scanned PDF detected. Please upload a digitally-generated PDF or take a screenshot instead."}` (OCR is a stretch goal, not v1)

**Error handling:** Password-protected files, corrupt files, and unsupported formats return `{:error, reason}` with a user-friendly message.

### 3. Multi-File Upload in SpreadsheetLive

**File:** `lib/rho_web/live/spreadsheet_live.ex`

Add `allow_upload` in `mount/3`:

```elixir
|> allow_upload(:files,
  accept: ~w(.xlsx .csv .pdf .jpg .jpeg .png .webp),
  max_entries: 10,
  max_file_size: 10_000_000
)
```

#### Upload Limits

| Constraint | Limit | Enforced By |
|------------|-------|-------------|
| Per-file size | 10MB | LiveView `max_file_size` (client + server) |
| Max files per message | 10 | LiveView `max_entries` |
| Accepted types | .xlsx .csv .pdf .jpg .jpeg .png .webp | LiveView `accept` (client + server) |
| Total upload per message | 50MB | Custom validation in `handle_event` (LiveView only enforces per-file) |

The total upload limit prevents a user from uploading 10 x 10MB files (100MB) which would strain memory. Custom validation rejects with a flash message: "Total upload size exceeds 50MB. Please upload fewer or smaller files."

#### Upload UI Changes

The chat input area needs these additions to the render template:

- **Attach button** (paperclip icon) next to the textarea, triggers `<.live_file_input upload={@uploads.files} />`
- **File chips** above the textarea showing selected files before send: filename + type icon + "x" remove button. Use `@uploads.files.entries` to render.
- **Upload progress** per file (LiveView's built-in `entry.progress` percentage)
- **Parse status** after send: show "Parsing files..." spinner while async parsing runs, then "Parsed 45 rows from tech_skills.xlsx" on completion
- **Error display** when a file fails to parse: red chip with error message

Allow sending with files but no text (current code rejects empty messages):

```elixir
def handle_event("send_message", %{"content" => content}, socket) do
  content = String.trim(content)
  has_files = @uploads.files.entries != []
  if content == "" and not has_files, do: {:noreply, socket}, else: do_send_with_files(content, socket)
end
```

#### Async File Parsing

File parsing MUST NOT block the LiveView process. A large PDF could take 5-10 seconds via Pythonx. Parse asynchronously:

```elixir
defp do_send_with_files(content, socket) do
  # 1. Consume uploaded entries (just copy temp files, fast)
  file_entries = consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
    # Copy to a stable location (temp files get cleaned up)
    stable_path = Path.join(System.tmp_dir!(), "rho_upload_#{System.unique_integer([:positive])}_#{entry.client_name}")
    File.cp!(path, stable_path)
    {:ok, %{filename: entry.client_name, path: stable_path, mime: entry.client_type}}
  end)

  if file_entries == [] do
    # No files — send plain text immediately
    do_send_message(content, socket)
  else
    # 2. Show "Parsing files..." state
    socket = assign(socket, :parsing_files, true)

    # 3. Parse all files asynchronously via Task.Supervisor
    parent = self()
    Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
      results = Enum.map(file_entries, fn entry ->
        result = Rho.FileParser.parse(entry.path, entry.mime)
        File.rm(entry.path)  # Clean up temp copy
        %{filename: entry.filename, result: result}
      end)
      send(parent, {:files_parsed, content, results})
    end)

    {:noreply, socket}
  end
end

def handle_info({:files_parsed, content, file_results}, socket) do
  socket = assign(socket, :parsing_files, false)
  socket = store_parsed_files(socket, file_results)
  {text_summary, image_parts} = build_file_context(file_results)
  enriched_content = build_submit_content(content, text_summary, image_parts)
  do_send_message(enriched_content, socket)
end
```

**Known limitation (v1):** Parsed file data is stored in `socket.assigns.parsed_files`. If the LiveView process crashes or the user refreshes, parsed data is lost. The user would need to re-upload. Persisting to disk or ETS is a v2 improvement.

**File summary format** (injected as text, NOT full data):

```
[Uploaded files]
- tech_skills.xlsx: 45 rows, 3 columns (Category, Skill, Description). Sample:
  Row 1: {Category: "Technical", Skill: "Python Programming", Description: "Ability to write..."}
  Row 2: {Category: "Technical", Skill: "Data Analysis", Description: "Capability to..."}
  Row 3: {Category: "Leadership", Skill: "Team Management", Description: "Skill in..."}
  Use get_uploaded_file("tech_skills.xlsx") to read all rows.

- leadership_ref.pdf: 3 pages, extracted text (2,847 chars). Prose content, no clean tables detected.
  Use get_uploaded_file("leadership_ref.pdf") to read full text.

- whiteboard.jpg: Image uploaded. Visual content available in this message.
```

Images are included as `ContentPart.image()` multimodal parts alongside the text. Structured/text files are summarized with a pointer to the `get_uploaded_file` tool.

### 4. get_uploaded_file Tool (New, in Spreadsheet Mount)

**File:** `lib/rho/mounts/spreadsheet.ex`

New tool added to the spreadsheet mount's `tools/2`:

```elixir
%{
  tool: ReqLLM.tool(
    name: "get_uploaded_file",
    description: "Read parsed content of an uploaded file. For large files (>200 rows), returns first 200 rows by default — use offset/limit to paginate.",
    parameter_schema: [
      filename: [type: :string, required: true, doc: "Filename as shown in the upload summary"],
      sheet: [type: :string, required: false, doc: "Sheet name for multi-sheet Excel files. Defaults to first sheet."],
      offset: [type: :integer, required: false, doc: "Start row (0-based). Default: 0"],
      limit: [type: :integer, required: false, doc: "Max rows to return. Default: 200"]
    ]
  ),
  execute: fn args ->
    with_pid(session_id, fn pid ->
      ref = make_ref()
      send(pid, {:get_uploaded_file, {self(), ref}, args["filename"]})
      receive do
        {^ref, {:ok, data}} -> {:ok, Jason.encode!(data)}
        {^ref, {:error, reason}} -> {:error, reason}
      after
        5_000 -> {:error, "Spreadsheet did not respond in time"}
      end
    end)
  end
}
```

SpreadsheetLive handles `{:get_uploaded_file, ...}` by looking up the filename in `assigns.parsed_files` and returning the full parsed data.

### 5. read_resource Tool (New, in Skills Mount)

**File:** `lib/rho/skills.ex`

New tool added alongside the existing `skill` tool. Enables Tier 3 progressive disclosure from the agentskills.io spec.

```elixir
%{
  tool: ReqLLM.tool(
    name: "read_resource",
    description: "Read a resource file from an active skill's directory. Use when a skill's instructions reference a file in references/ or scripts/.",
    parameter_schema: [
      skill: [type: :string, required: true, doc: "Skill name"],
      file: [type: :string, required: true, doc: "Relative path, e.g. 'references/import-workflow.md'"]
    ]
  ),
  execute: fn args -> execute_read_resource(args, workspace, skills) end
}
```

**Security:** Path traversal guard — resolved path must stay within the skill directory:

```elixir
defp execute_read_resource(args, _workspace, skills) do
  skill_name = args["skill"]
  file_path = args["file"]

  case Enum.find(skills, &(String.downcase(&1.name) == String.downcase(skill_name))) do
    nil -> {:error, "Skill not found: #{skill_name}"}
    skill ->
      skill_dir = Path.dirname(skill.location)
      resolved = Path.expand(Path.join(skill_dir, file_path))

      if String.starts_with?(resolved, skill_dir) do
        case File.read(resolved) do
          {:ok, content} -> {:ok, content}
          {:error, _} -> {:error, "File not found: #{file_path}"}
        end
      else
        {:error, "Path traversal denied"}
      end
  end
end
```

### 6. Spreadsheet Agent Config Changes

**File:** `.rho.exs`

```elixir
spreadsheet: [
  # ... existing config ...
  mounts: [
    :spreadsheet,
    :skills,  # NEW — enables skill discovery + read_resource
    {:multi_agent, only: [:delegate_task, :await_task, :list_agents]}
  ],
  system_prompt: """
  You are a skill framework editor assistant. $framework-editor

  Use the framework-editor skill to guide your workflow.
  For simple edits, use spreadsheet tools directly.
  """
]
```

The `$framework-editor` hint triggers `expanded_hints()` to auto-expand the skill body into the prompt — zero round-trip cost.

The current monolithic system prompt (intake + skeleton + proficiency generation instructions) moves into `references/generate-workflow.md`. The system prompt becomes thin.

### 7. Multimodal Support in SpreadsheetLive

Port the image handling pattern from `SessionLive`:

```elixir
# In send_message handler, after parsing files:
image_parts = Enum.flat_map(file_results, fn
  %{result: {:image, base64, media_type}} ->
    [ReqLLM.Message.ContentPart.image(Base64.decode64!(base64), media_type)]
  _ -> []
end)

# Build multimodal content if images present
submit_content =
  if image_parts != [] do
    text_parts = if enriched_text != "", do: [ReqLLM.Message.ContentPart.text(enriched_text)], else: []
    text_parts ++ image_parts
  else
    enriched_text
  end
```

Verify that `Rho.Reasoner.Structured` passes multimodal user messages through to the LLM API correctly (not just text content).

## Data Flow Diagrams

### Flow 1: Import Excel File

```
User uploads tech_skills.xlsx + types "Import this"
  │
  ▼
SpreadsheetLive.consume_uploaded_entries()
  │
  ▼
Rho.FileParser.parse(path, "application/vnd...xlsx")
  → Pythonx: scripts/parse_excel.py
  → {:structured, %{rows: [45 maps], columns: ["Category","Skill","Description"], row_count: 45}}
  │
  ▼
Store in assigns.parsed_files, inject summary into message
  │
  ▼
Agent receives: "Import this" + "[Uploaded: tech_skills.xlsx — 45 rows, 3 columns...]"
  │
  ▼
Agent: skill already expanded via $framework-editor hint
  → Intent table: file uploaded + "import" → Import
  → read_resource("framework-editor", "references/import-workflow.md")
  │
  ▼
Import workflow says: read file, propose column mapping, confirm with user
  → get_uploaded_file("tech_skills.xlsx") → full 45 rows
  → "I'll map Category→category, Skill→skill_name, Description→skill_description. No proficiency levels found. OK?"
  │
  ▼
User confirms → add_rows(mapped data) → spreadsheet populated
```

### Flow 2: Upload Image for Interpretation

```
User uploads whiteboard.jpg + types "Extract the framework from this photo"
  │
  ▼
Rho.FileParser.parse(path, "image/jpeg")
  → {:image, base64_data, "image/jpeg"}
  │
  ▼
Image included as ContentPart.image() in multimodal message
  │
  ▼
Agent receives: text + image content part
  → Intent table: image + "extract" → Import (unstructured)
  → read_resource("framework-editor", "references/import-workflow.md")
  │
  ▼
Agent interprets image via vision, extracts framework structure
  → Proposes skills found in the image
  → Confirms with user → add_rows()
```

### Flow 3: Reference-Based Generation

```
User uploads competitor_framework.pdf + types "Build something similar for our data engineering team"
  │
  ▼
Rho.FileParser.parse(path, "application/pdf")
  → scripts/parse_pdf.py → {:text, "extracted prose..."} (no clean tables)
  │
  ▼
Summary in message: "competitor_framework.pdf: 5 pages, prose content"
  │
  ▼
Agent: Intent → Reference + Generate
  → read_resource("framework-editor", "references/reference-workflow.md")
  → get_uploaded_file("competitor_framework.pdf") → full text
  → Extracts patterns: categories, naming conventions, level structure
  │
  ▼
  → read_resource("framework-editor", "references/generate-workflow.md")
  → Runs intake (informed by reference), skeleton, proficiency generation
  → New framework in spreadsheet, inspired by but not copied from reference
```

## Scope

### v1 (This Spec)

- Single `framework-editor` skill with router + 4 reference workflows
- `read_resource` tool in `Rho.Skills` mount
- `Rho.FileParser` module with Excel/CSV/PDF/image support
- Multi-file upload in `SpreadsheetLive` (up to 10 files, 10MB each)
- `get_uploaded_file` tool for lazy data loading
- Multimodal message support in `SpreadsheetLive`
- Column mapping by agent (not automated)
- `:skills` mount added to spreadsheet agent
- Thin system prompt with `$framework-editor` auto-expansion

### v1 Supported File Types

| Format | Extension | Parser | Output |
|--------|-----------|--------|--------|
| Excel (modern) | .xlsx | openpyxl via Pythonx | Structured rows |
| CSV | .csv | Python csv module | Structured rows |
| PDF (digital) | .pdf | pdfplumber via Pythonx | Structured rows or text |
| Images | .jpg .jpeg .png .webp | Base64 encode | Multimodal content part |

### Not in v1 (Future)

- Old Excel format (.xls) — requires xlrd, different library
- Scanned PDF OCR — requires pytesseract + pdf2image
- Apple Numbers (.numbers), LibreOffice (.ods)
- Automatic column mapping (v1 is agent-proposed, user-confirmed)
- File drag-and-drop (v1 uses click-to-upload)
- **Export to Excel** — download the spreadsheet as .xlsx. Natural fast-follow after import+enhance. Architecture supports it: pair `parse_excel.py` with `export_excel.py`, add `export_table` tool to spreadsheet mount
- Persisting parsed file data to disk/ETS (survives LiveView crash)
- Skill-to-skill composition
- `$ARGUMENTS` / `${RHO_SKILL_DIR}` variable substitution in skill bodies

## Files Changed

### New Files

| File | Purpose |
|------|---------|
| `lib/rho/file_parser.ex` | File parsing router module |
| `priv/python/file_parser/parse_excel.py` | Excel/CSV parser (openpyxl + chardet) |
| `priv/python/file_parser/parse_pdf.py` | PDF parser (pdfplumber) |
| `priv/python/file_parser/detect_structure.py` | Table vs prose classifier |
| `.agents/skills/framework-editor/SKILL.md` | Skill router |
| `.agents/skills/framework-editor/references/*.md` | 7-8 reference workflow files |

### Modified Files

| File | Change |
|------|--------|
| `lib/rho/skills.ex` | Add `read_resource` tool |
| `lib/rho/mounts/spreadsheet.ex` | Add `get_uploaded_file` tool |
| `lib/rho_web/live/spreadsheet_live.ex` | Add `allow_upload`, file parsing pipeline, multimodal message assembly, `parsed_files` assigns handling |
| `.rho.exs` | Add `:skills` mount, `python_deps`, thin system prompt with `$framework-editor` hint |
| `lib/rho_web/inline_css.ex` | Upload UI styling (file chips, progress indicators) |

### Unchanged

| File | Why |
|------|-----|
| `lib/rho/mount.ex` | Mount behaviour unchanged |
| `lib/rho/mount_registry.ex` | Registry unchanged |
| `lib/rho/agent_loop.ex` | Loop unchanged |
| `lib/rho/reasoner/structured.ex` | Verify multimodal passthrough works, but likely no changes needed |
| `lib/rho/skill.ex` | Skill discovery unchanged (already parses SKILL.md from `.agents/skills/`) |
