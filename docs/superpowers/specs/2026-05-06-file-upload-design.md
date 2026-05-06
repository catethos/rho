# File Upload & Ingestion — Design Spec

**Status:** Approved for implementation (post-review revision r1).
**Date:** 2026-05-06.
**Branch:** `rho_regina`.
**Author:** Regina, with Claude as design pair.
**Approach:** Approach B (balanced v1 — Excel/CSV in chat, DocIngest unification, PDF/image and library-page UI deferred to v2).
**Review history:** Independent INTJ architecture review on 2026-05-06 surfaced 16 findings (3 CRITICAL, 5 HIGH, 4 MEDIUM, 4 LOW). All CRITICAL and HIGH findings resolved in this revision; MEDIUMs and select LOWs incorporated. Notable product call: v1 rejects `:roles_per_sheet` files with a clear error rather than silently importing skills without role mapping. See §3 and §5.3.

---

## 1. Problem

Solution consultants and clients arrive with existing skill frameworks already authored in spreadsheets. Today they cannot drop those files into the product:

- The chat surface (`apps/rho_web/lib/rho_web/live/app_live.ex`) accepts image uploads only — `allow_upload(:images, ...)`. There is no upload affordance for `.xlsx`, `.csv`, `.pdf`, or `.docx`.
- The library detail page (`apps/rho_web/lib/rho_web/live/skill_library_show_live.ex`) has no upload control at all.
- The agent has `Rho.Stdlib.Plugins.DocIngest`, but it accepts a server-side absolute path. That only works for developers; end users have no way to make the agent see a file.
- `DocIngest` has a latent param-validation bug: the agent supplies `format: "xlsx"` (intuitive from the file extension) and the matcher only accepts `"excel" | "pdf" | "word"`, so the call fails with a misleading error message that mentions `.xlsx` as a supported format. Confirmed in the Phoenix log on 2026-05-06.
- Two real-world sample files prove the import pipeline must accommodate fundamentally different shapes:
  - `complete_framework_import.xlsx` — 1 sheet `Framework`, 9 columns including explicit `Skill Library Name`, `Role`, `Category`, `Cluster`, `Skill Name`, `Skill Description`, `Level`, `Level Name`, `Level Description`. Every (skill, level) pair is a row. **Library name is in the data, sheet name is generic.**
  - `test_framework_import.xlsx` — 3 sheets named `Product Manager`, `Data Engineer`, `CEO`, each with 3 columns: `Skill Name`, `Category`, `Description`. **Sheet names are roles. No library name. No proficiency levels.**

The convention "sheet name = library name" does not survive contact with these files. We need a pipeline that handles both shapes deterministically when columns are clear, and asks one targeted question when they are not.

---

## 2. Goals

1. **Drag-and-drop upload in chat** for `.xlsx` and `.csv`, parity with existing image upload.
2. **Cheap observation summary** the agent reads as a single-paragraph injection in the next user message — full data stays on the server, paginated on demand.
3. **Single import path** — the same UseCase serves the chat-side tool and the future library-page wizard step. No code duplication between surfaces.
4. **Eliminate the format-string bug class** — the agent never names the format; routing is driven by the file extension captured at upload (with browser MIME as a soft cross-check). The agent never sees a `format:` parameter.
5. **Provenance** — rows imported from an upload carry `_source: "upload"` and a free-text `_reason` containing the filename and upload id (e.g. `"imported from complete_framework_import.xlsx (upl_a1b2c3d4)"`). No schema migration required; `_reason` is already an optional column on the existing `library_schema`.
6. **Compose with the existing agent topology** — the spreadsheet agent delegates to `data_extractor` only when LLM judgement is required (prose PDFs, images), not for clean structured files.

## 3. Non-goals (v1)

These are deliberately out of scope. Each non-goal is a v2 line item, not a permanent omission.

- **PDF parsing bodies.** Layer 2 routing handles `application/pdf` but returns `{:error, :not_yet_supported}`. The branch exists; the parser implementation lands in v2.
- **Image OCR or vision-based extraction.** Images can still be sent to the LLM as multimodal input via the existing `:images` channel. The new file-upload channel does not handle them in v1.
- **Library-page upload button.** The library detail page gets no upload control. Users land in chat to import. v2 adds a thin "Import library" entry point that opens chat with the file pre-attached.
- **Multi-file batch upload.** v1 supports one file per message. The upload server accepts multiple handles; the agent's import tool processes one at a time.
- **Persistent upload storage across server restarts.** Files live in `System.tmp_dir!/rho_uploads/<session_id>/` with a per-session GenServer holding the metadata. Server restart loses uploads. Re-upload is fine for v1.
- **Schema-aware merging on import.** Existing `combine_libraries` handles merge after import. v1's import always creates a fresh `library:<name>` table; if the name collides with an existing draft we fail with a clear error and let the user pick a new name.
- **`:roles_per_sheet` file imports.** v1 detects this shape in the observation (sheet name = role, no library column, e.g. `test_framework_import.xlsx`) but the import tool returns `{:error, {:roles_per_sheet_unsupported_v1, sheets}}` with a precise next-step message: *"This file has 3 sheets that look like roles. v1 imports one library per file. Either flatten the sheets into one with a `Skill Library Name` column, or upload each sheet as its own library. v2.5 will handle role-per-sheet imports natively."* The agent surfaces this verbatim to the user. Writing `role_profile` rows from a level-less, requirement-less sheet would require inventing values for `required_level` (integer, required) and `required` (boolean, required); we refuse to invent product semantics.

---

## 4. Architecture

Three layers. Each layer answers exactly one question. Each can be replaced without touching the others.

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  Job 1: UPLOAD       — "store these bytes safely"                   │
│  ─────────────────────────────────────────────────                  │
│  Generic. File-agnostic. Returns a stable handle ID.                │
│  Lives in: apps/rho_stdlib/lib/rho/stdlib/uploads/                  │
│                                                                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ %Handle{id, filename, mime, path, ...}
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  Job 2: OBSERVE      — "what is in this file?"                      │
│  ─────────────────────────────────────────────────                  │
│  Per-MIME parsers. Returns a uniform summary struct.                │
│  Does NOT decide what to do with the contents.                      │
│  Lives in: apps/rho_stdlib/lib/rho/stdlib/uploads/observer.ex       │
│                                                                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ %Observation{kind, sheets, hints, warnings}
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  Job 3: ACT          — "use this observation to do something"       │
│  ─────────────────────────────────────────────────                  │
│  Domain-specific. v1 implements one action: import_library.         │
│  Lives in: apps/rho_frameworks/lib/rho_frameworks/use_cases/        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**Why three layers, not one:**

- Adding `.pdf` later changes only Job 2.
- Adding the library-page button changes only the front door of Job 1.
- Adding `use_upload_as_reference` (a sibling of `import_library`) changes only Job 3.
- Re-parsing the same file for a different action does not re-upload, does not re-parse — Job 2's result is cached against the upload handle.

The layers communicate through two structs (`%Handle{}`, `%Observation{}`) which are the only contracts that need to remain stable. Adding fields to either struct is safe; renaming requires touching exactly one parser and one consumer.

---

## 5. Component specs

### 5.1 Layer 1 — `Rho.Stdlib.Uploads` (generic upload server)

**Location:** `apps/rho_stdlib/lib/rho/stdlib/uploads/`

**Modules:**

- `Rho.Stdlib.Uploads` — public client API.
- `Rho.Stdlib.Uploads.Server` — per-session `GenServer` holding handle metadata in state.
- `Rho.Stdlib.Uploads.Supervisor` — `DynamicSupervisor` for per-session servers, mirroring `Rho.Stdlib.DataTable.Supervisor`.
- `Rho.Stdlib.Uploads.Registry` — `Registry` for `{session_id}` → server pid lookup, mirroring `Rho.Stdlib.DataTable.Registry`.
- `Rho.Stdlib.Uploads.SessionJanitor` — listens for `rho.agent.stopped` and cleans up the matching server + temp files. Same pattern as `Rho.Stdlib.DataTable.SessionJanitor`.
- `Rho.Stdlib.Uploads.Handle` — pure struct.

**Public API:**

```elixir
# --- per-session API (LV + agent path) -------------------------------
@spec ensure_started(session_id :: String.t()) :: :ok
@spec put(session_id :: String.t(),
          %{filename: String.t(),
            mime: String.t(),
            tmp_path: String.t(),    # path to copy from (LV temp file)
            size: non_neg_integer()}) :: {:ok, Handle.t()} | {:error, term()}
@spec get(session_id :: String.t(), upload_id :: String.t()) :: {:ok, Handle.t()} | :error
@spec list(session_id :: String.t()) :: [Handle.t()]
@spec delete(session_id :: String.t(), upload_id :: String.t()) :: :ok
@spec read_bytes(session_id :: String.t(), upload_id :: String.t()) :: {:ok, binary()} | {:error, term()}

# --- one-shot path API (DocIngest shim path) -------------------------
# Used by callers that have a server-side file path and want a single
# parse without participating in a session lifecycle. No GenServer is
# spawned. Caller-owned file is NOT deleted; this function only reads.
@spec parse_one_off(path :: String.t()) ::
        {:ok, Observation.t()} | {:error, term()}
```

**Session-scoping note:** All `Uploads.{get,list,delete,read_bytes}` operations are scoped to `session_id` — an upload created in session A is invisible to session B even if the upload id were known. The id (`"upl_" <> 16 hex chars` = 64 bits of randomness) is for human readability and tape entries; security comes from session-scoping, not id unguessability.

**Handle struct:**

```elixir
defmodule Rho.Stdlib.Uploads.Handle do
  @type t :: %__MODULE__{
          id: String.t(),               # "upl_" <> 16 hex chars
          session_id: String.t(),
          filename: String.t(),         # original client filename
          mime: String.t(),             # browser-supplied MIME, validated against accept list
          size: non_neg_integer(),
          path: String.t(),             # stable absolute path under tmp dir
          uploaded_at: DateTime.t(),
          observation: Observation.t() | nil    # cached after Job 2 runs
        }

  defstruct [:id, :session_id, :filename, :mime, :size, :path, :uploaded_at, observation: nil]
end
```

**Storage model:**

- Bytes live on disk under `System.tmp_dir!/rho_uploads/<session_id>/<upload_id><ext>`.
- Per-session `GenServer` holds the metadata map `%{upload_id => Handle{}}` in process state. (No ETS — the per-session server already serializes writes; we don't gain concurrency from ETS for what is effectively a small in-memory map per session.)
- `restart: :temporary` on the server so a crashed server stays down — callers get `{:error, :not_running}` rather than a silently empty server. Mirrors the DataTable pattern.

**Lifecycle:**

1. LV calls `Uploads.ensure_started(session_id)` from `mount/3`.
2. On file submit, LV runs `consume_uploaded_entries(:files, ...)`. Inside the callback, it copies the LV temp file to the stable upload path and calls `Uploads.put/2`.
3. `Uploads.put` returns a `Handle{}` with a fresh `upload_id`.
4. The `SessionJanitor` listens for `Rho.Events.subscribe/1` events with type `rho.agent.stopped` (the same signal that tears down the DataTable server). On match, it tells the `Uploads.Server` to **drain** (see §5.2 cleanup ordering), then calls `Uploads.Supervisor.terminate_child/2`. The `Server`'s `terminate/2` callback (with `Process.flag(:trap_exit, true)`) is responsible for `File.rm_rf!/1` of the `rho_uploads/<session_id>/` directory — this guarantees files are deleted only after in-flight parse Tasks have finished or been cancelled, eliminating the read-after-delete race flagged in review.

**Crash + leftover-file handling (server-restart resilience):** Because `restart: :temporary` means a crashed `Uploads.Server` does NOT come back in the same session, files written before the crash would normally leak until the agent stops. Two complementary safeguards:

1. The supervisor's `child_spec` includes a `terminate_child` hook that does `File.rm_rf!("#{tmp_root}/#{session_id}")` even if the server is already dead.
2. `Uploads.ensure_started/1` runs `File.mkdir_p!/1` and `File.rm_rf!/1` in idempotent sequence on first start of a session (so a stale directory from a crashed prior server in the same session id is wiped). This is safe because no other process owns those files.

**Validation:**

| Constraint | Limit | Enforced where |
|---|---|---|
| Per-file size | 10 MB | `allow_upload(:files, max_file_size: 10_000_000)` in LV (client + server). |
| Files per upload event | 5 | `allow_upload(:files, max_entries: 5)`. v1 import processes one at a time; multiple uploads queue as separate handles. |
| Accepted MIME types | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`, `text/csv`, `application/pdf` (stub), `image/jpeg`, `image/png`, `image/webp` (passthrough only) | `accept: ~w(.xlsx .csv .pdf .jpg .jpeg .png .webp)` + **extension-first** kind detection in `Uploads.put` (see below). |

**MIME / extension resolution.** Browsers send wildly inconsistent MIME types for the same file. Safari sends `.csv` as `application/vnd.ms-excel`; some Linux Firefox builds send `text/plain`; copy-pasted files often arrive as `application/octet-stream`. Strict MIME matching would reject perfectly valid uploads from a real fraction of users. Algorithm in `Uploads.put`:

1. Resolve `kind` from the **file extension** of `filename` (`.xlsx → :excel`, `.csv → :csv`, `.pdf → :pdf`, `.jpg/.jpeg/.png/.webp → :image`). Extension is canonical.
2. Use the browser-supplied MIME only as a soft cross-check for telemetry / observability (logged on mismatch but not enforced).
3. Reject only when the extension is not in the accept list (which is what `allow_upload(accept: ...)` already enforces client-side).

This keeps validation user-friendly while preserving the "the agent never names the format" property — kind comes from the upload, not from the LLM.

**Failure modes:**

- LV temp file gone before copy → return `{:error, :tmp_file_missing}`. Caller surfaces "Upload failed, please retry."
- Disk full on copy → `{:error, {:io_error, reason}}`. Caller surfaces a flash.
- Unsupported MIME → `{:error, {:unsupported_mime, mime}}`. LV blocks the upload chip with a per-entry error before submit.

### 5.2 Layer 2 — `Rho.Stdlib.Uploads.Observer`

**Location:** `apps/rho_stdlib/lib/rho/stdlib/uploads/observer.ex`

**Responsibility:** Open a `Handle{}`, dispatch to a per-MIME parser, return a uniform `%Observation{}`. Cache the result back onto the handle (via `Uploads.Server`) so subsequent calls are free.

**Public API:**

```elixir
@spec observe(session_id :: String.t(), upload_id :: String.t()) ::
        {:ok, Observation.t()} | {:error, term()}

@spec read_sheet(session_id :: String.t(), upload_id :: String.t(),
                 sheet :: String.t() | nil,
                 opts :: [offset: non_neg_integer(), limit: pos_integer()]) ::
        {:ok, %{columns: [String.t()], rows: [map()], total: non_neg_integer()}}
        | {:error, term()}
```

**Observation struct:**

```elixir
defmodule Rho.Stdlib.Uploads.Observation do
  @type kind :: :structured_table | :prose | :image | :unsupported

  @type sheet_summary :: %{
          name: String.t(),
          row_count: non_neg_integer(),
          columns: [String.t()],
          sample_rows: [map()]            # up to 3 sample rows for the agent's eye
        }

  @type hints :: %{
          # Layer 2's best guess at how to map this to library/role/skill.
          # Each *_column value is the ORIGINAL header string from the file (preserved case),
          # not a normalized form — Layer 3 uses it to read raw cell values.
          # Layer 3 (or the agent) decides whether to follow the hint.
          library_name_column: String.t() | nil,
          role_column: String.t() | nil,
          skill_name_column: String.t() | nil,
          skill_description_column: String.t() | nil,
          category_column: String.t() | nil,
          cluster_column: String.t() | nil,
          level_column: String.t() | nil,
          level_name_column: String.t() | nil,
          level_description_column: String.t() | nil,
          sheet_strategy: :single_library
                        | :roles_per_sheet
                        | :ambiguous
        }

  @type t :: %__MODULE__{
          kind: kind(),
          sheets: [sheet_summary()],      # [] for non-tabular kinds
          hints: hints(),
          warnings: [String.t()],
          summary_text: String.t()        # ~3-line text the agent injects into chat
        }

  defstruct kind: :unsupported,
            sheets: [],
            hints: %{},
            warnings: [],
            summary_text: ""
end
```

**Per-extension routing** (extension is canonical per §5.1; MIME shown for reference only):

| Extension | Reference MIME | Parser | Output `kind` |
|---|---|---|---|
| `.xlsx` | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` | `Observer.Excel.parse/1` (Xlsxir) | `:structured_table` |
| `.csv` | `text/csv` (or any of `application/vnd.ms-excel`, `text/plain`, `application/octet-stream` per browser) | `Observer.Csv.parse/1` (`NimbleCSV` or stdlib) | `:structured_table` |
| `.pdf` | `application/pdf` | `Observer.Pdf.parse/1` — **v1 stub returns `{:error, :not_yet_supported}`** | `:unsupported` (v1) |
| `.jpg / .jpeg / .png / .webp` | `image/*` | `Observer.Image.parse/1` — passthrough metadata only (dimensions, byte count) | `:image` |
| any other | — | — | `:unsupported` |

**Excel/CSV column-detection algorithm:**

For each sheet, normalize header strings (lowercase, strip punctuation, collapse whitespace) and match against alias lists:

```
:library_name_column  ← ["skill library name", "library name", "library", "framework name"]
:role_column          ← ["role", "role name", "job role", "position"]
:skill_name_column    ← ["skill name", "skill", "competency", "competence"]
:skill_description_column ← ["skill description", "description", "definition", "what it means"]
:category_column      ← ["category", "domain", "area", "group"]
:cluster_column       ← ["cluster", "sub-category", "sub-domain", "subgroup"]
:level_column         ← ["level", "proficiency level", "tier"]
:level_name_column    ← ["level name", "tier name"]
:level_description_column ← ["level description", "tier description", "indicator"]
```

`sheet_strategy` is derived:

- 1 sheet AND `library_name_column != nil` → `:single_library`
- 1 sheet AND no library column → `:single_library` (assume sheet content is one library, name unspecified)
- N sheets AND each sheet has the same columns AND no `library_name_column` → `:roles_per_sheet` (sheet name = role)
- N sheets AND `library_name_column != nil` in any sheet → `:single_library` (library spans sheets, library name comes from the column)
- otherwise → `:ambiguous` (push the question to the user)

**Warnings populated on detection issues** (these surface verbatim into `summary_text` so the agent reads them):

- `"No skill name column found — required."` if `skill_name_column == nil`.
- `"Sheet '<name>' has no rows."` per empty sheet.
- `"Multi-sheet file with no library name column — sheet names look like roles. v1 imports one library per file (see import error for next steps)."` for `:roles_per_sheet`. The wording is tuned to match the reject behaviour from §3 / §5.3 — never promises auto-import.
- `"Sheet structures are inconsistent — explicit library_name and role_strategy required."` for `:ambiguous`.

**`summary_text` shape** (3 lines max, what gets injected into the next user message):

```
[Uploaded: complete_framework_import.xlsx]
1 sheet "Framework", 26 rows. Columns: Skill Library Name, Role, Category, Cluster, Skill Name, Skill Description, Level, Level Name, Level Description.
Detected: single library (from Skill Library Name column).
```

```
[Uploaded: test_framework_import.xlsx]
3 sheets (Product Manager, Data Engineer, CEO), ~6 rows each. Columns: Skill Name, Category, Description.
Detected: roles per sheet (sheet name = role). v1 supports one library per file — see import error for next steps.
```

**Caching + concurrent-call serialization:** `observe/2` runs **inside the per-session `Uploads.Server` mailbox** (a `GenServer.call` that performs the parse synchronously in the server process when no cached observation exists). This serializes concurrent observers of the same upload — N concurrent agent turns calling `observe(upload_id)` collapse into one parse. The cached `%Observation{}` is then attached to the `Handle{}` and returned to all callers in FIFO order. Subsequent `observe/2` calls return the cached value without entering the parser. `read_sheet/4` runs OUT of the server (direct disk read) on every call and is not cached — that's what `:offset/:limit` is for.

**Invocation timing — two paths:**

1. **LV-initiated first parse.** Inside the LV's `handle_event("send_message", ...)` after `consume_uploaded_entries`, the LV calls `observe/2` via `Task.Supervisor.async_nolink/2` so the LV stays responsive. The Task's `GenServer.call` will serialize behind the per-session server's mailbox; the Task itself is the only thing holding the parsing wait. The LV shows a "parsing..." chip until the Task replies (or times out — see §8).
2. **Agent-tool-initiated parse** (e.g. `observe_upload` tool). Runs as a normal `GenServer.call` from inside the agent worker process. If the LV already kicked off a parse Task, this call simply waits in the same mailbox queue and gets the cached result. No duplicate parsing.

Excel/CSV parsing of typical real-world files (≤200 rows × ≤20 columns) completes in well under 2 seconds. **Pathological wide-or-tall sheets at the 10MB ceiling can exceed 30 seconds**; the parse timeout (15s, see Failure modes below) hard-caps this. A Phase 2 verification step includes a "wide pathological sheet" test fixture (1,000 rows × 50 columns) to confirm timeout behavior is graceful.

**Failure modes:**

- Encrypted/password-protected `.xlsx` → Xlsxir returns `{:error, ...}`; we surface `{:error, :encrypted_file}`.
- Corrupt file → `{:error, :corrupt_file}`.
- Sheet with zero columns → `Observation{kind: :structured_table, warnings: ["empty sheet"], ...}`. Not an error.
- Parser timeout (15s hard cap via `Task.async_nolink` + `Task.shutdown(:brutal_kill)`) → `{:error, :parse_timeout}`.

### 5.3 Layer 3 — `RhoFrameworks.UseCases.ImportFromUpload`

**Location:** `apps/rho_frameworks/lib/rho_frameworks/use_cases/import_from_upload.ex`

**Responsibility:** Take an `upload_id` and an explicit mapping, write rows into a `library:<name>` named DataTable, return a summary the agent can speak. This is the only domain-aware layer.

**Behaviour:** implements `RhoFrameworks.UseCase` so it can be invoked from the wizard's FlowRunner in v2 with no changes.

**Input:**

```elixir
@type input :: %{
        upload_id: String.t(),
        library_name: String.t() | nil,         # nil → use observation hint or filename
        role_strategy: :single_library
                     | :roles_per_sheet
                     | nil,                     # nil → use observation hint
        column_mapping: map() | nil,            # nil → use observation hints
        sheets: [String.t()] | nil              # nil → import all sheets that match strategy
      }
```

**Output (UseCase return):**

```elixir
{:ok, %{
   library_name: String.t(),
   table_name: String.t(),                      # "library:<name>"
   skills_imported: non_neg_integer(),
   roles_imported: non_neg_integer(),           # 0 if :single_library
   warnings: [String.t()]                       # passthrough from observation + import-time issues
}}
| {:error, reason}
```

**Algorithm:**

1. Resolve `role_strategy` first — it gates everything:
   - explicit input wins.
   - else `Observation.hints.sheet_strategy`.
   - **If `:roles_per_sheet`**, abort early: return `{:error, {:roles_per_sheet_unsupported_v1, sheet_names}}`. The tool wrapper translates this to a verbatim user-facing message (see §3 non-goals). No partial work, no DataTable mutation.
   - **If `:ambiguous`**, abort with `{:error, {:ambiguous_shape, hints}}` — the agent must ask the user for explicit `library_name` + `role_strategy` and re-call.
2. Resolve `library_name`:
   - explicit input wins.
   - else `Observation.hints.library_name_column` resolved against the first non-empty value across rows of the first eligible sheet.
   - else filename without extension.
   - On collision with an existing draft library: fail with `{:error, {:library_exists, name}}`.
3. Resolve `column_mapping`:
   - explicit input wins per-key.
   - else `Observation.hints` per-key.
   - Required columns missing (`skill_name_column == nil`) → fail with `{:error, {:missing_required, [:skill_name_column]}}`.
4. Compute `table_name = Editor.table_name(library_name)` (uses the existing `RhoFrameworks.Library.Editor` helper for `library:<name>` formatting — keeps naming consistent with `load_library`).
5. **Pre-create the named table.** This step is mandatory because `Workbench.replace_rows` operates on an existing named table and `library_schema` is `:strict`:
   ```elixir
   :ok = DataTable.ensure_started(scope.session_id)
   :ok = DataTable.ensure_table(scope.session_id, table_name, DataTableSchemas.library_schema())
   ```
   Mirrors `Workbench.load_framework/2` at `apps/rho_frameworks/lib/rho_frameworks/workbench.ex:151`.
6. Stream rows from `Observer.read_sheet/4` (paginated, no full materialization), normalize each into the `library_schema` row shape:
   - `category`, `cluster` (default `cluster: category` if no cluster column), `skill_name`, `skill_description`.
   - `proficiency_levels: [%{level, level_name, level_description}, ...]` — grouped by `(skill_name)` key when the file uses the "exploded" shape with a `level` column. Single-level rows (no level column) produce an empty `proficiency_levels` list.
   - `_source: "upload"`.
   - `_reason: "imported from #{filename} (#{upload_id})"` — provenance lives entirely in this free-text column. **No new schema columns are added.** The existing `library_schema` is unchanged. This trades structured query-by-upload-id (a v2 concern) for zero migration risk.
7. Call `Workbench.replace_rows(scope, rows, table: table_name)` (the canonical write path used by `load_library`).
8. Return summary.

**Tool wrapper:** `RhoFrameworks.Tools.WorkflowTools.import_library_from_upload` (added to the existing `WorkflowTools` module). The wrapper builds the input map, calls `ImportFromUpload.run/2`, and returns a `%Rho.ToolResponse{}` with:

- `text` — the agent-speakable summary.
- `effects: [%Rho.Effect.OpenWorkspace{key: :data_table}, %Rho.Effect.Table{table_name: table_name, schema_key: :skill_library, mode_label: "Skill Library — #{name}", rows: [], skip_write?: true}]` — same effect pattern `load_library` already uses (rows are written by the UseCase via Workbench; the effect just switches the UI tab).

This ensures the LV reacts identically whether the rows arrived via `load_library`, `generate_framework_skeletons`, or `import_library_from_upload`.

---

## 6. Tool surface for the agent

Four tools, three generic + one domain.

### 6.1 Generic tools — `Rho.Stdlib.Plugins.Uploads`

**New plugin** in `apps/rho_stdlib/lib/rho/stdlib/plugins/uploads.ex`. Registered atom shorthand `:uploads` in `Rho.Stdlib.@plugin_modules`.

```elixir
tool :list_uploads,
     "List files uploaded in this session." do
  run fn _args, ctx ->
    {:ok, Uploads.list(ctx.session_id) |> render_list()}
  end
end

tool :observe_upload,
     "Get a structured summary of an uploaded file: sheets, columns, sample rows, detected hints." do
  param :upload_id, :string, required: true
  run fn args, ctx ->
    case Observer.observe(ctx.session_id, args[:upload_id]) do
      {:ok, observation} -> {:ok, render_observation(observation)}
      {:error, reason} -> {:error, render_error(reason)}
    end
  end
end

tool :read_upload,
     "Read rows from an uploaded structured file. Defaults to first 200 rows of first sheet." do
  param :upload_id, :string, required: true
  param :sheet, :string, doc: "Sheet name (Excel only). Defaults to first sheet."
  param :offset, :integer, doc: "Default 0"
  param :limit, :integer, doc: "Default 200, max 1000"
  run fn args, ctx -> ... end
end
```

**No `bindings/2` callback.** An earlier draft proposed surfacing uploads as `Rho.Plugin` bindings. We removed it for two reasons:

1. **Double-counting.** Uploads are already injected into the next user message as `[Uploaded: ...]` blocks (see §8.3). Surfacing them again in `bindings/2` would duplicate that text in every turn for the entire lifetime of the upload — ~80 tokens per upload per turn for as long as the agent is alive. Pick one channel; the user message is the right one because it's contextually linked to the user's intent.
2. **Contract risk.** `Rho.Plugin`'s `binding/0` type at `apps/rho/lib/rho/plugin.ex:21-28` requires `persistence` (`:turn | :session | :derived`) and `access` (`:python_var | :tool | :resolver`). Adding bindings means committing to a contract whose evolution is tied to the plugin behaviour. We don't need that coupling.

The agent discovers uploads via the `list_uploads` tool (cheap call, no prompt cost) when it cares.

### 6.2 Domain tool — `RhoFrameworks.Tools.WorkflowTools.import_library_from_upload`

```elixir
tool :import_library_from_upload,
     "Import an uploaded structured file as a new skill library. " <>
       "Pass upload_id; library_name and role_strategy default to the observation's detected values." do
  param :upload_id, :string, required: true
  param :library_name, :string,
        doc: "If omitted, uses detected library column or the filename."
  param :role_strategy, :string,
        doc: "single_library or roles_per_sheet. Defaults to detected strategy."
  param :sheets, :string,
        doc: "Comma-separated sheet names to import. Defaults to all eligible."

  run fn args, ctx ->
    scope = Scope.from_context(ctx)
    input = build_input(args)
    case ImportFromUpload.run(input, scope) do
      {:ok, summary} -> render_response(summary)
      {:error, reason} -> {:error, render_error(reason)}
    end
  end
end
```

This tool is added to the spreadsheet agent via the existing `RhoFrameworks.Plugin` registration in `.rho.exs` (no new entry — `WorkflowTools` is already loaded).

---

## 7. Agent topology

Confirmed via `apps/rho_stdlib/lib/rho/stdlib/plugins/multi_agent.ex:142-155` (`build_role_hint`) and `.rho.exs` lines 75-77:

- **`spreadsheet` agent** already has `{:multi_agent, only: [:delegate_task, :delegate_task_lite, :await_task, :await_all], visible_agents: [:data_extractor]}`. It can spawn `data_extractor` today; no plumbing changes needed.
- **`data_extractor` agent** has `plugins: [:doc_ingest]` only. It cannot delegate further — leaf agent. Bounded by `@max_depth = 3` (currently unused since data_extractor has no multi_agent plugin).

**v1 routing rule (added to `spreadsheet` system_prompt):**

> When the user uploads a file, your first step is `observe_upload(upload_id)` to read the summary.
>
> - If `observation.kind == :structured_table` and `sheet_strategy == :single_library` with no warnings about missing required columns, call `import_library_from_upload(upload_id)` directly. Defaults will use the detected hints.
> - If `observation.kind == :structured_table` but `sheet_strategy == :ambiguous` or `library_name_column` is missing on a single-sheet file, ask the user one targeted question (library name), then call `import_library_from_upload` with the answer.
> - If `sheet_strategy == :roles_per_sheet`, **do not call `import_library_from_upload`** — it will return a v1-unsupported error. Instead, tell the user verbatim: *"This file has N sheets that look like roles. v1 imports one library per file. Either flatten the sheets into one with a `Skill Library Name` column, or upload each sheet as its own library."* Wait for the user's choice.
> - If `observation.kind == :prose` or `observation.kind == :image`, delegate to `data_extractor` with `delegate_task(role: "data_extractor", task: "extract structured framework data from upload <id>")`. Receive the JSON via `await_task`, then call `import_library_from_upload` with the structured input. (v1 does not exercise this branch — PDF parsing is stubbed — but the rule is in place for v2.)
> - If `observation.kind == :unsupported`, tell the user what file types are supported.
>
> **Critical guardrail:** Never use `read_upload` followed by `add_rows` to "manually" import a structured library. `read_upload` returns rows with header strings as keys (e.g. `"Skill Name"`) which the `library` table's strict schema (atom keys like `:skill_name`) will reject. `import_library_from_upload` is the only correct path — it owns the column mapping. `read_upload` is for inspection only (a few rows, sanity check).

**v1 reality check:** because v1 has no PDF parser body (Layer 2 returns `:unsupported` for PDFs), the delegation branch for `:prose` is defined but not exercised. We declare the rule now so v2's PDF arrival is a Layer-2 change only — the agent rule is already in place.

**`data_extractor` system_prompt update:** it loses `ingest_document` from its plugin list and gains the `:uploads` plugin (which gives it `read_upload`). Its prompt is rewritten:

> You are a data extraction sub-agent. You receive an `upload_id` and a description of the file. Use `read_upload(upload_id)` to read content. Return a single JSON object matching the existing schema (skills, roles, issues). You do not interact with the user — your output goes back to the parent agent.

This narrows its job from "find the file, parse it, structure it" to "structure the content of an already-parsed file." Smaller surface, fewer failure modes, faster turn.

---

## 8. UI integration (chat surface, `app_live.ex`)

### 8.1 Mount

Add a sibling `allow_upload(:files, ...)` next to the existing `:images`:

```elixir
|> allow_upload(:files,
  accept: ~w(.xlsx .csv .pdf .jpg .jpeg .png .webp),
  max_entries: 5,
  max_file_size: 10_000_000
)
|> assign(:files_parsing, %{})           # %{ref => filename} for in-flight Task.refs
|> assign(:files_parse_errors, [])
|> then(fn s ->
     if connected?(s), do: Uploads.ensure_started(s.assigns.session_id), else: s
   end)
```

### 8.2 Render

Above the existing chat input form (`apps/rho_web/lib/rho_web/live/app_live.ex:2775`), add a file-chip strip:

```heex
<div :if={@uploads.files.entries != [] or @files_parsing != %{}}
     class="chat-attach-strip">
  <%= for entry <- @uploads.files.entries do %>
    <div class={["chat-attach-chip", entry.errors != [] && "is-error"]}>
      <span class="chat-attach-icon"><%= file_icon(entry.client_type) %></span>
      <span class="chat-attach-name"><%= entry.client_name %></span>
      <span :if={entry.progress < 100} class="chat-attach-progress"><%= entry.progress %>%</span>
      <button type="button"
              phx-click="cancel_file"
              phx-value-ref={entry.ref}
              class="chat-attach-remove">×</button>
    </div>
  <% end %>
  <div :for={{_ref, name} <- @files_parsing} class="chat-attach-chip is-parsing">
    <span class="chat-attach-icon">⏳</span>
    <span class="chat-attach-name"><%= name %></span>
    <span class="chat-attach-progress">parsing…</span>
  </div>
</div>

<form id="chat-input-form" phx-submit="send_message" class="chat-input-form">
  <label class="chat-attach-button" title="Attach file">
    📎
    <.live_file_input upload={@uploads.files} class="sr-only" />
  </label>
  <textarea name="content" ...></textarea>
  ...
</form>
```

CSS additions live in `apps/rho_web/lib/rho_web/inline_css.ex` next to existing chat styles.

### 8.3 Submit handler

Extend `handle_event("send_message", ...)` in `app_live.ex:1447`. The current handler consumes `:images` and builds multimodal content. The new handler also consumes `:files`:

```elixir
def handle_event("send_message", %{"content" => content}, socket) do
  content = String.trim(content)

  image_parts = consume_uploaded_entries(socket, :images, &build_image_part/2)
  file_consumes = consume_uploaded_entries(socket, :files, &consume_file_to_handle(&1, &2, socket.assigns.session_id))

  cond do
    content == "" and image_parts == [] and file_consumes == [] ->
      {:noreply, socket}

    file_consumes == [] ->
      # No files — existing path
      submit(socket, content, image_parts)

    true ->
      # Files present — kick off parsing, defer submit until parses complete
      socket = arm_parse_tasks(socket, content, image_parts, file_consumes)
      {:noreply, socket}
  end
end

defp consume_file_to_handle(%{path: tmp_path}, entry, session_id) do
  case Uploads.put(session_id, %{
         filename: entry.client_name,
         mime: entry.client_type,
         tmp_path: tmp_path,
         size: entry.client_size
       }) do
    {:ok, handle} -> {:ok, {:handle, handle}}
    {:error, reason} -> {:postpone, {:error, reason, entry.client_name}}
  end
end
```

`arm_parse_tasks/4` spawns one `Task.Supervisor.async_nolink` per handle calling `Observer.observe/2`. Stores `%{task_ref => %{filename: ..., handle_id: ...}}` in `assigns.files_parsing`. On every `:DOWN` from a parse Task the LV checks if all parses are done; once `files_parsing == %{}`, it builds the enriched message:

```
<user_text>

[Uploaded: file1.xlsx]
<file1.summary_text>

[Uploaded: file2.csv]
<file2.summary_text>
```

…and submits via the existing `submit/3` path with image parts unchanged.

**Failure-mode coverage** (each must produce a clean user-visible state, no stuck UI):

| Event | LV behaviour |
|---|---|
| Parse Task replies `{:ok, observation}` | Remove ref from `files_parsing`. If empty, build enriched message and submit. |
| Parse Task replies `{:error, reason}` | Remove ref. The corresponding `[Uploaded: ...]` block becomes `[Upload error: <filename>: <reason>]` and the message still goes through. |
| Parse Task crashes (`:DOWN` with non-`:normal`) | Treat identically to `{:error, :crashed}`. Log via `Logger.warning`. |
| Parse Task exceeds 15s timeout (`Task.shutdown(:brutal_kill)` from Observer) | Identical to `{:error, :parse_timeout}`. |
| User clicks **Cancel** on a parsing chip | LV sends `{:cancel_parse, ref}` to itself, calls `Task.Supervisor.terminate_child/2`, removes the ref, and (if `files_parsing` is now empty AND user already hit Send) submits the partial message. |
| LV process crashes mid-parse | Linked `Task.Supervisor.async_nolink` Tasks are not linked to the LV — they continue running. Their reply messages eventually arrive at a dead pid and are dropped silently. The on-disk upload directory is reaped by the `SessionJanitor` on agent stop. **No leak, no orphan state.** |
| User navigates away mid-parse (LV unmount) | Same as crash — Tasks complete, replies are dropped. |
| User hits Send a second time before the first parse finishes | The textarea + Send button are both `disabled` while `files_parsing != %{}`. The CSS state is bound to `assigns.files_parsing` so it can never go out of sync with the actual queue. |

The blocking model is intentional: a half-imported library is worse than a 2-second wait. The 15s timeout caps the worst case.

### 8.4 Library page (v1 stub)

No UI changes to `skill_library_show_live.ex` in v1. v2 adds:

```heex
<button phx-click="open_chat_with_upload" class="library-import-btn">
  + Import library from file
</button>
```

clicking which navigates to the chat with `?attach_file=true` (chat opens its file picker on mount). No new code paths — same Job 1 → Job 2 → Job 3 flow.

---

## 9. DocIngest migration

`Rho.Stdlib.Plugins.DocIngest` stays — `data_extractor` keeps using `ingest_document` until the agent prompt swap lands. The internals refactor uses the **one-shot** API from §5.1, not the per-session API:

```elixir
# apps/rho_stdlib/lib/rho/stdlib/plugins/doc_ingest.ex (after refactor)
defp extract(_format, path) do
  case Rho.Stdlib.Uploads.parse_one_off(path) do
    {:ok, observation} -> {:ok, format_observation_as_text(observation)}
    {:error, reason}   -> {:error, "Ingest failed: #{inspect(reason)}"}
  end
end
```

`Uploads.parse_one_off/1`:

- Reads the caller-owned file at `path` directly (no copy).
- Detects kind from the path's extension (same algorithm as §5.1).
- Calls the same `Observer.parse_*` functions the per-session path uses.
- Returns the `Observation{}` synchronously.
- **Spawns no GenServer.** **Creates no temp files.** **Owns no cleanup responsibility** — the input file belongs to the caller.

This is the corrected design (an earlier draft proposed a `:standalone` session id that would have leaked GenServer state and temp files). The shim shares the parser without sharing the lifecycle.

The format-param bug disappears: the `format` parameter on `ingest_document` becomes ignored (kept for backward-compat in the schema, doc string updated to "deprecated, format is auto-detected from extension"). `Rho.Stdlib.Plugins.DocIngest` is also marked `@deprecated "Prefer the file upload pipeline (Rho.Stdlib.Plugins.Uploads) for new code. ingest_document is kept for path-based callers."` so future readers see compiler warnings if they wire it into new agents.

**Migration sequencing:**

1. Land Layer 1 + Layer 2 + the `:uploads` plugin tools.
2. Land `import_library_from_upload`.
3. Update `spreadsheet` system prompt (the v1 routing rule).
4. Refactor `DocIngest.extract/2` to delegate to Observer. Verify `data_extractor`'s existing scenarios still pass.
5. Update `data_extractor` plugins from `[:doc_ingest]` to `[:uploads]` and rewrite its prompt to use `read_upload`. (Keep `:doc_ingest` registered globally for any other callers — there are none today, but the cost is zero.)

Step 4 is the riskiest step. It touches a tool the existing `data_extractor` agent calls today. Mitigation: the existing scenario tests (`docs/product-scenarios-skill-framework.md` Scenario 9 et al, on `skill_framework`) exercise `data_extractor` end-to-end. We re-run those before merging step 4.

---

## 10. Schemas / persistence

**No DB migrations required. No `library_schema` changes required.**

Earlier drafts proposed adding a `:_source_upload_id` column to `RhoFrameworks.DataTableSchemas.library_schema/0`. We dropped that approach in revision r1 because:

- `library_schema` is `mode: :strict`, which means rows with extra unknown columns are rejected. Adding a column would force every existing in-session `library:<name>` table to be re-`ensure_table`d with the new schema; sessions that loaded a library before the column was added would hit `:schema_mismatch` from `Server.handle_call({:ensure_table, ...})` (`apps/rho_stdlib/lib/rho/stdlib/data_table/server.ex:163-181`). That's a session-restart cliff.
- The provenance need is satisfied by the existing optional `_reason` column. We write `_reason: "imported from #{filename} (#{upload_id})"`. Querying by upload id becomes free-text grep instead of a structured filter — acceptable for v1, where provenance is a debugging aid, not a queryable feature.

Database persistence (when `save_framework` runs) is unchanged. Skill records in the DB have no upload provenance. v2 may add a structured `source` JSONB column on the Skill table if/when this becomes a real query — that requires a migration and is explicitly out of scope.

---

## 11. Implementation phasing (engineering sequence)

Ordered for low-risk merging. Each phase is independently shippable and testable.

| # | Phase | Files | Verification |
|---|---|---|---|
| 1 | Upload server + supervisor + janitor + one-shot API | `apps/rho_stdlib/lib/rho/stdlib/uploads/{server.ex,supervisor.ex,session_janitor.ex,handle.ex}` + new `apps/rho_stdlib/lib/rho/stdlib/uploads.ex` (public client API including `parse_one_off/1`) + supervision tree wiring in `Rho.Stdlib.Application.start/2` (place new children after `Rho.Stdlib.DataTable.SessionJanitor` so the upload janitor inherits the same lifecycle ordering) + new `Registry` named `Rho.Stdlib.Uploads.Registry` | Unit test: put → get → list → delete; janitor cleans on `rho.agent.stopped`; `parse_one_off/1` runs with no GenServer spawned and no temp files created |
| 2 | Observer + Excel/CSV parsers + Observation struct | `apps/rho_stdlib/lib/rho/stdlib/uploads/{observer.ex,observation.ex}` + `apps/rho_stdlib/lib/rho/stdlib/uploads/observer/{excel.ex,csv.ex,pdf.ex,image.ex}` (PDF/image as `:not_yet_supported` stubs returning correct kind metadata) | Unit test against both sample files (`complete_framework_import.xlsx`, `test_framework_import.xlsx`): column detection, sheet_strategy, warnings, summary_text. PLUS a wide-pathological fixture (1000 rows × 50 cols) to confirm the 15s timeout fires gracefully. |
| 3 | LV file-upload affordance | `apps/rho_web/lib/rho_web/live/app_live.ex` (`mount/3` adds `allow_upload(:files, ...)` and `Uploads.ensure_started/1`; `handle_event("send_message")` extended; new `arm_parse_tasks/4`, `handle_info({ref, ...})`, `handle_event("cancel_file", ...)`); `apps/rho_web/lib/rho_web/inline_css.ex` (file-chip styles) | Manual: drag both sample files into chat; chips render; parse status flips to ready; summary appears in next user message; cancel button works mid-parse; second file pending while first is mid-parse keeps Send disabled |
| 4 | `:uploads` plugin (generic tools) | `apps/rho_stdlib/lib/rho/stdlib/plugins/uploads.ex` (new) + add `:uploads` shorthand to `@plugin_modules` in `apps/rho_stdlib/lib/rho/stdlib.ex` + add `:uploads` to the spreadsheet agent's `plugins:` list in `.rho.exs` | Unit: each tool exec calls the right `Uploads.*` / `Observer.*` function and surfaces correct errors; concurrent `observe_upload` calls collapse to a single parse. |
| 5 | `ImportFromUpload` UseCase + WorkflowTools wrapper | `apps/rho_frameworks/lib/rho_frameworks/use_cases/import_from_upload.ex` (new) + add `tool :import_library_from_upload` block to `apps/rho_frameworks/lib/rho_frameworks/tools/workflow_tools.ex`; **no changes** to `data_table_schemas.ex` | Unit: input → `ensure_table` → rows → `Workbench.replace_rows`; `complete_framework_import.xlsx` succeeds end to end; `test_framework_import.xlsx` returns `{:error, {:roles_per_sheet_unsupported_v1, _}}` cleanly; `:library_exists` collision case fails clean |
| 6 | `spreadsheet` agent prompt update | `.rho.exs` (spreadsheet agent's `system_prompt`) — fold in §7 routing rule including the `read_upload + add_rows` guardrail | E2E: drop `complete_framework_import.xlsx` in chat → agent imports without asking; drop `test_framework_import.xlsx` → agent surfaces the v1-unsupported message verbatim, no partial mutation |
| 7 | `DocIngest` refactor (one-shot delegate to Observer) | `apps/rho_stdlib/lib/rho/stdlib/plugins/doc_ingest.ex` (replace `extract/2` body with `Uploads.parse_one_off/1` call; mark module `@deprecated`) | Re-run existing `data_extractor` scenarios from `skill_framework` branch; format-param bug no longer reproducible whether agent passes `format: "xlsx"`, `"excel"`, `nil`, or `"banana"` |
| 8 | `data_extractor` plugins + prompt swap | `.rho.exs` (`data_extractor` agent: `plugins: [:uploads]` instead of `[:doc_ingest]`; rewrite `system_prompt` per §7) | E2E: spawn `data_extractor` directly with an `upload_id`; receives JSON output. Optional for v1; can ship in v2 alongside PDF. |

Phases 1-2 are pure stdlib additions, no risk to existing flows.
Phase 3 touches `app_live.ex` — incremental addition next to existing `:images` upload, no behavior change to existing paths.
Phase 4 adds new tools — no conflict with existing tools.
Phase 5 adds a new UseCase + tool — no conflict.
Phase 6 changes one agent's system prompt — easy revert.
Phase 7 is the highest-risk single change. Run scenario tests pre-merge.
Phase 8 is the cleanup. Optional for v1; can ship in v2 alongside PDF.

A reasonable shipping cut: phases 1-6 are v1. Phase 7 lands when scenarios are green. Phase 8 ships with v2 PDF support.

---

## 12. Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `DocIngest` refactor regresses `data_extractor` | Medium | High (broken sub-agent) | Run all `skill_framework` data_extractor scenarios pre-merge. Phase 7 is mergeable independently — can be reverted without unwinding phases 1-6. The `parse_one_off/1` API has its own unit tests independent of any agent path. |
| SessionJanitor races an in-flight parse Task (file deleted while Task reads) | Medium | Medium (parse crash + LV log noise) | Cleanup ordering enforced in `Server.terminate/2` with `Process.flag(:trap_exit, true)`: file deletion happens AFTER all in-flight `GenServer.call` parses have replied. Janitor sends `:drain` before `terminate_child/2`. Parse Tasks swallow `:noproc` and `{:error, :not_running}` with a `Logger.warning` — never crashes the LV. |
| Concurrent `observe_upload` calls cause thundering-herd reparse | Medium (multi-agent topologies) | Medium (CPU + duplicate work) | `observe/2` runs inside the per-session `Uploads.Server` mailbox (see §5.2). Concurrent callers serialize and the second through Nth caller gets the cached observation set by the first. |
| Async parse race: user sends a second message before parse completes | Medium | Medium (out-of-order injection) | Textarea + Send button are `disabled` while `files_parsing != %{}`. CSS state is bound to the assign so it can never go out of sync. Parse timeouts always re-enable. |
| Large file parse times exceed 15s timeout | Medium (pathological wide sheets) | Medium (failed import) | 15s timeout via `Task.shutdown(:brutal_kill)`. Surface `{:error, :parse_timeout}` to the user with "file too large or too complex — try splitting." Phase 2 verification includes a wide-pathological fixture to confirm the timeout fires gracefully. |
| Two simultaneous uploads in one message | Low | Low | Each handle gets its own parse Task; submit waits for all via `files_parsing` map. |
| Per-session GenServer crashes mid-parse | Low | Medium (lose handle metadata) | `restart: :temporary` — caller gets `{:error, :not_running}` from `Registry` lookup (clean error, not a silent empty state). On next `ensure_started/1`, the supervisor's `terminate_child` hook + `init/1`'s idempotent `mkdir_p! / rm_rf!` clean any stale on-disk files. User re-uploads. |
| LV process crashes mid-parse | Low | Low | `async_nolink` Tasks are not linked to the LV. Their replies hit a dead pid and are dropped silently. Files are reaped by `SessionJanitor` on agent stop. No leak. |
| `library:<name>` collision with existing draft | Medium | Low (clear error) | UseCase fails with `{:error, {:library_exists, name}}`, agent asks user for a new name. Existing `Library.resolve_library/3` provides the collision check. |
| LLM hallucinates `upload_id` | Low | Low (clean error) | `Uploads.get/2` returns `:error` for unknown ids; tool returns "upload not found" — agent self-corrects. |
| Agent skips `import_library_from_upload` and tries `read_upload + add_rows` | Medium | Medium (rejected rows, agent retries) | System prompt guardrail in §7. The strict library schema rejects header-string keys, surfacing the error to the agent as `{:error, :unknown_columns, [...]}` from `add_rows` — which agent uses to switch to the correct path. |
| Browser sends inconsistent MIME for `.csv` (Safari sends `application/vnd.ms-excel`) | High (will hit some users) | Medium (rejected upload) | Extension-first kind detection (see §5.1). MIME is logged for telemetry but not enforced. |
| ~~Schema column addition breaks existing `library_schema` consumers~~ — **N/A in r1** | — | — | Resolved by dropping `_source_upload_id` entirely (see §10). |

---

## 13. Out of scope (explicit)

Listed for the avoidance of doubt. Each is a v2 scope item, not a permanent omission.

- **PDF body parsing.** Routing exists; parser stub returns `:not_yet_supported`.
- **Image vision extraction via the `:files` channel.** Image vision still works through the existing `:images` channel; the `:files` channel passes images to Observer which returns `:image` kind metadata only.
- **Library-page upload UI.** Stubbed for v2 as a thin entry that opens chat with the file pre-attached.
- **Multi-file batch import** in a single tool call. v1 imports one file per `import_library_from_upload` call.
- **Persistent upload storage** across server restarts.
- **Structured upload-id provenance on rows.** v1 stores provenance as free text in `_reason` (e.g. `"imported from foo.xlsx (upl_a1b2c3d4)"`). Querying by upload id is grep-only. A structured column requires a schema change and is deferred.
- **Upload provenance propagation to the saved DB record.** Skill records in the DB carry no upload trace. Add a `source` JSONB column on the Skill table when this becomes a real query — requires a real migration.
- **DocIngest deprecation/removal.** v1 keeps `:doc_ingest` registered and `ingest_document` callable; v2 evaluates whether anything still uses it.

---

## 14. Open questions

None at design-approval time (r1).

Settled in r1 from review:
- **Role-per-sheet handling** — v1 rejects cleanly; v2.5 implements role_profile writes properly. Rationale: writing strict `role_profile` rows requires `required_level` and `required` values that the file does not contain. Inventing them would be a silent product downgrade.
- **Provenance column** — dropped in favor of free-text `_reason`. No schema migration.
- **Bindings vs. message injection** — message injection only. Avoids double-counting tokens.
- **`:standalone` session id in DocIngest shim** — replaced with `Uploads.parse_one_off/1` API. No session lifecycle, no temp files.

Implementation may surface details (specific Xlsxir API quirks for wide sheets, exact CSS for the parsing chip animation, the precise BAML schema string for the spreadsheet agent's routing rule) — those are implementation choices that do not change the architecture.

---

## Appendix A — Worked example: `complete_framework_import.xlsx`

User drops the file. LV consumes 12,345 bytes, copies to `/tmp/rho_uploads/lv_26755/upl_a1b2c3d4.xlsx`, calls `Uploads.put` and gets:

```elixir
%Handle{
  id: "upl_a1b2c3d4",
  session_id: "lv_26755",
  filename: "complete_framework_import.xlsx",
  mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  size: 12_345,
  path: "/tmp/rho_uploads/lv_26755/upl_a1b2c3d4.xlsx",
  uploaded_at: ~U[2026-05-06 11:42:00Z],
  observation: nil
}
```

LV spawns `Observer.observe("lv_26755", "upl_a1b2c3d4")`. Inside:

- `Excel.parse/1` reads the file. Single sheet "Framework". 26 rows. Headers detected.
- Column detection matches `Skill Library Name` → `library_name_column`, `Role` → `role_column`, `Skill Name` → `skill_name_column`, `Level` → `level_column`, etc.
- `sheet_strategy = :single_library` (one sheet AND library_name_column present).
- No warnings.
- `summary_text = "[Uploaded: complete_framework_import.xlsx]\n1 sheet \"Framework\", 26 rows. Columns: Skill Library Name, Role, ... .\nDetected: single library (from Skill Library Name column)."`

Observer caches the observation back to the handle. LV's submit completes:

```
User typed: "import this please"

Enriched message sent to spreadsheet agent:
  import this please

  [Uploaded: complete_framework_import.xlsx]
  1 sheet "Framework", 26 rows. Columns: Skill Library Name, Role, Category, Cluster, Skill Name, Skill Description, Level, Level Name, Level Description.
  Detected: single library (from Skill Library Name column).
```

Spreadsheet agent's first turn:

1. Reads the system prompt routing rule.
2. Sees `kind == :structured_table`, no warnings, library_name_column detected.
3. Skips the question, calls `import_library_from_upload(upload_id: "upl_a1b2c3d4")`.

`import_library_from_upload`:

1. Calls `ImportFromUpload.run(%{upload_id: "upl_a1b2c3d4"}, scope)`.
2. UseCase resolves `role_strategy = :single_library` (from observation hints — no early abort).
3. Resolves `library_name = "HR Manager"` (from `library_name_column` value in the first row).
4. Resolves column mapping from `Observation.hints` (no overrides supplied).
5. Computes `table_name = Editor.table_name("HR Manager") = "library:HR Manager"`.
6. `DataTable.ensure_started(scope.session_id)` and `DataTable.ensure_table(scope.session_id, "library:HR Manager", DataTableSchemas.library_schema())`.
7. Streams rows via `Observer.read_sheet`, groups by `(skill_name)` to build `proficiency_levels` arrays. Each row gets `_source: "upload"` and `_reason: "imported from complete_framework_import.xlsx (upl_a1b2c3d4)"`.
8. Calls `Workbench.replace_rows(scope, rows, table: "library:HR Manager")`.
9. Returns `{:ok, %{library_name: "HR Manager", table_name: "library:HR Manager", skills_imported: 1, roles_imported: 0, warnings: []}}`. (`roles_imported: 0` because v1's `:single_library` strategy doesn't write `role_profile` rows; `Role` column is preserved per-row in the library table only.)

Tool returns `%Rho.ToolResponse{}` with effects. EffectDispatcher writes the table-switch event. UI flips to the data table tab showing the imported library.

Agent says: *"Imported 'HR Manager' — 1 skill (Recruitment Strategy) with 5 proficiency levels. Ready when you are to save."*

User hits save. `save_framework` (existing tool) persists.

End to end: 2 LV round-trips, 1 LLM call (the import was one tool call), ~4 seconds wall clock.

## Appendix B — Worked example: `test_framework_import.xlsx`

User drops the file. Observation produces:

```
sheets: [
  %{name: "Product Manager", row_count: 6, columns: ["Skill Name", "Category", "Description"], sample_rows: [...]},
  %{name: "Data Engineer",   row_count: 5, columns: ["Skill Name", "Category", "Description"], sample_rows: [...]},
  %{name: "CEO",             row_count: 7, columns: ["Skill Name", "Category", "Description"], sample_rows: [...]}
]
hints: %{
  skill_name_column: "Skill Name",
  category_column: "Category",
  skill_description_column: "Description",
  library_name_column: nil,
  role_column: nil,
  level_column: nil,
  sheet_strategy: :roles_per_sheet
}
warnings: ["Multi-sheet file with no library name column — sheet names will be treated as roles."]
summary_text: "[Uploaded: test_framework_import.xlsx]\n3 sheets (Product Manager, Data Engineer, CEO), ~6 rows each. Columns: Skill Name, Category, Description.\nDetected: roles per sheet — no library name in file, please confirm library name when importing."
```

Spreadsheet agent's first turn (per the v1 routing rule in §7):

1. Reads the observation — `sheet_strategy == :roles_per_sheet`.
2. Per the routing rule, **does not call `import_library_from_upload`**. Instead surfaces the v1-unsupported message verbatim:

> *"This file has 3 sheets that look like roles (Product Manager, Data Engineer, CEO). v1 imports one library per file. Two ways forward:*
>
> *1. Flatten the sheets into one with a `Skill Library Name` column (and ideally a `Role` column).*
> *2. Save each sheet as its own `.xlsx` and upload them as separate libraries (Product Manager library, Data Engineer library, CEO library).*
>
> *Which would you like to do?"*

3. User picks an option, takes the suggested action outside the chat, eventually re-uploads in a v1-supported shape (e.g. one of the sheets saved as its own file). The next iteration follows Appendix A's flow.

End to end for the rejection: **1 LLM call. Zero partial mutation. Zero made-up `required_level` values written to the database.** The product is honest about its v1 scope rather than silently demoting a multi-role file into a flat skill list.

**v2.5 future-state (non-binding sketch):** when role-per-sheet is supported, the agent will instead ask: *"Should the library be called 'Product Org' (default) or something else? And what proficiency levels should I assume for each role's skills — `1` (foundational) or `3` (proficient)?"* — those answers fill the required `required_level` and `required` fields on `role_profile_schema`. Until that v2.5 design is settled, the v1 rejection path is the right behaviour.

---

*End of spec.*
