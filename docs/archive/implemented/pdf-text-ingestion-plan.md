# Upload Handles + Lightweight Prose Reading - Plan

**Date:** 2026-05-13  
**Status:** Revised implementation plan  
**Supersedes:** The earlier markitdown/Python-first PDF ingestion draft.

## 1. Decision

Do not build a universal "convert every document to markdown" pipeline as the
foundation for JD extraction.

Rho already has the right shared primitive: a per-session upload handle with a
stable server-side path. The elegant design is:

```text
Phoenix LiveView upload
  -> Rho.Stdlib.Uploads stores file once
  -> returns upload_id

Excel/CSV
  -> parse immediately for sheet/column hints
  -> observe_upload/read_upload/import_library_from_upload

PDF job descriptions
  -> do not locally parse before send
  -> extract_role_from_jd(upload_id)
  -> tool reads raw PDF bytes and passes them to BAML pdf input

TXT/MD/HTML/DOCX
  -> lightweight pure-Elixir text extraction when needed
```

Python/markitdown is not part of the default path. If future real-world PDFs
show provider PDF input is inadequate, add an optional fallback later.

## 2. Goals

1. Extend chat uploads beyond `.xlsx`/`.csv` without forcing every file through
   the same parse-before-send path.
2. Keep Excel/CSV behavior unchanged: parse asynchronously, block Send while
   pending, inject sheet summary plus `upload_id`.
3. Let PDFs upload cheaply and immediately: store the file and inject a short
   `upload_id` block; do not locally extract PDF text by default.
4. Add lightweight pure-Elixir prose observation for easy formats:
   `.txt`, `.md`, `.markdown`, `.html`, `.htm`; `.docx` can be added after the
   upload-handle change if needed.
5. Preserve one upload system and one `upload_id` concept for all file kinds.

## 3. Non-goals

- OCR for scanned/image-only PDFs.
- Universal high-fidelity PDF-to-markdown conversion.
- Python/markitdown dependency.
- Generic prose Q&A over large documents as part of the JD extraction work.
- A new persistence layer for uploads. Uploads stay per-session and temporary.

## 4. Current State

LiveView currently accepts only `.xlsx` and `.csv` in the `:files` upload slot:

```elixir
allow_upload(:files,
  accept: ~w(.xlsx .csv),
  max_entries: 5,
  max_file_size: 10_000_000
)
```

On send, every file is copied into `Rho.Stdlib.Uploads.Server`, then
`arm_parse_tasks/5` calls `Rho.Stdlib.Uploads.Observer.observe/2` for every
handle before the chat message is submitted.

That is correct for Excel/CSV, but too heavy for PDFs whose primary consumer is
a structured JD extraction tool that can pass raw PDF bytes directly to BAML.

## 5. Target Architecture

### 5.1 Upload storage stays universal

Keep:

- `Rho.Stdlib.Uploads.Server`
- `Rho.Stdlib.Uploads.Handle`
- `upload_id`
- per-session temporary directory cleanup

Every accepted file type is stored through `Uploads.put/2`.

### 5.2 Observation becomes kind-specific

Add a cheap classification layer:

```elixir
@type upload_kind ::
        :structured_table
        | :pdf
        | :prose_text
        | :docx
        | :image
        | :unsupported
```

The important distinction:

- `:structured_table` requires immediate parse.
- `:pdf` does not require immediate parse.
- `:prose_text` may be parsed immediately because it is cheap.
- `:docx` may initially be stored-only, then parsed later with pure Elixir.

### 5.3 LiveView send behavior

Split uploaded handles into two groups:

```elixir
parse_now?(".xlsx") -> true
parse_now?(".csv") -> true
parse_now?(".txt") -> true
parse_now?(".md") -> true
parse_now?(".markdown") -> true
parse_now?(".html") -> true
parse_now?(".htm") -> true
parse_now?(".pdf") -> false
parse_now?(".docx") -> false
```

Only `parse_now? == true` files create async parse tasks that block message
submission. Non-parsed files are immediately represented by lightweight upload
blocks.

Mixed uploads must work. If a user attaches one Excel file and one PDF, the
message waits only for the Excel parse. The PDF block is included immediately.

### 5.4 Chat message injection

For parsed Excel/CSV:

```text
[Uploaded: skills.xlsx]
1 sheet "Sheet1", 42 rows. Columns: ...
Detected: single library ...
[upload_id: upl_abc]
```

For stored-only PDF:

```text
[Uploaded: senior-backend-engineer.pdf]
PDF uploaded. Use upload_id with extract_role_from_jd for JD extraction.
[upload_id: upl_abc]
```

For cheap prose text:

```text
[Uploaded: notes.md]
Markdown document, 1,240 characters.

--- Document preview ---
...
--- End preview ---
[upload_id: upl_abc]
```

Use a small aggregate inline budget for prose previews, not a per-file-only
budget. Suggested defaults:

- `@inline_file_preview_chars 8_000`
- `@inline_total_preview_chars 16_000`

If the total preview budget is exhausted, inject only the summary and
`upload_id`.

## 6. File-Type Handling

### 6.1 Excel/CSV

No behavior change.

Existing paths remain:

- `observe_upload`
- `read_upload`
- `import_library_from_upload`

### 6.2 PDF

PDF upload support means "store and make addressable by upload_id", not "parse
to text immediately".

`Observer.parse_path/1` can return a lightweight `%Observation{kind: :pdf}` with
summary only:

```elixir
%Observation{
  kind: :pdf,
  summary_text: "[Uploaded: file.pdf] PDF uploaded.",
  warnings: []
}
```

No `read_upload_text` is required for the JD workflow.

### 6.3 TXT/MD

Implement in pure Elixir:

- read file
- normalize invalid UTF-8 safely
- count chars
- generate preview under budget

### 6.4 HTML

Use existing `Floki` dependency:

- parse document
- discard `script`, `style`, and hidden-ish nodes when practical
- extract headings, paragraphs, list items, and table cell text
- output plain markdown-ish text

### 6.5 DOCX

Defer unless needed for the first JD path. When implemented, use pure Elixir:

- DOCX is a ZIP
- read `word/document.xml`
- parse XML
- extract paragraphs and tables

No Python dependency is needed for basic DOCX text.

## 7. Tool Surface

Keep `Rho.Stdlib.Plugins.Uploads` small:

- `list_uploads`
- `observe_upload`
- `read_upload` for structured table rows only

Do not add `read_upload_text` until there is a real general-document Q&A need.

JD extraction belongs in `RhoFrameworks.Tools.WorkflowTools.extract_role_from_jd`
and should consume the raw upload handle directly.

## 8. Implementation Steps

1. Extend `Rho.Stdlib.Uploads.Observation.kind` with `:pdf` and
   `:prose_text`.
2. Add helper `Rho.Stdlib.Uploads.Observer.kind_for_path/1` or equivalent
   public/private classification used by both Observer and LiveView.
3. Extend LiveView `allow_upload(:files)` accept list:

   ```elixir
   ~w(.xlsx .csv .pdf .docx .txt .md .markdown .html .htm)
   ```

4. Refactor `arm_parse_tasks/5` so only `parse_now?` handles are parsed
   asynchronously.
5. For non-parsed handles, add lightweight observations directly to
   `files_pending_send.observations` or a sibling `upload_blocks` structure.
6. Add `Observer` clauses:
   - `.pdf` -> lightweight `:pdf` observation
   - `.txt`/`.md` -> `:prose_text` observation with preview
   - `.html`/`.htm` -> `:prose_text` observation via Floki
   - `.docx` -> either lightweight stored-only observation or deferred parser
7. Update `Uploads` plugin renderers so `observe_upload` is not table-specific.
8. Update tests.

## 9. Tests

### 9.1 Unit tests

- `Observer.parse_path/1` returns `:pdf` summary for a PDF path.
- `Observer.parse_path/1` returns `:prose_text` with preview for `.txt`.
- `Observer.parse_path/1` returns `:prose_text` with extracted text for `.html`.
- `Observer.read_sheet/4` still works for `.xlsx`/`.csv`.
- `Observer.read_sheet/4` returns `{:error, :not_a_table}` or equivalent for
  PDF/prose.

### 9.2 LiveView tests

- Upload `.xlsx`: message waits for parse and includes sheet summary.
- Upload `.pdf`: message does not attempt PDF text parsing and includes
  `upload_id`.
- Upload `.xlsx` plus `.pdf`: message waits for `.xlsx` parse only and includes
  both blocks.
- Upload `.md`: message includes preview under budget.
- Five uploaded prose files respect aggregate preview budget.

### 9.3 Regression tests

- Existing Excel import flow still passes.
- Existing `import_library_from_upload(upload_id:)` still rejects unsupported
  observation kinds cleanly.

## 10. Acceptance Criteria

- Users can attach `.pdf`, `.docx`, `.txt`, `.md`, `.markdown`, `.html`, `.htm`,
  `.xlsx`, and `.csv` in the same file upload slot.
- Excel/CSV behavior is unchanged from the current product.
- PDF upload creates a stable `upload_id` and does not invoke local PDF text
  extraction before sending the chat message.
- A chat message containing only a PDF upload can be sent and includes a clear
  instruction-style block mentioning `extract_role_from_jd`.
- A mixed PDF + Excel upload sends after the Excel parse completes; the PDF does
  not add parse latency.
- `observe_upload(upload_id:)` works for PDF and returns a useful summary.
- `read_upload(upload_id:)` remains table-only and returns a clear error for
  PDF/prose uploads.
- No Python dependency is added.
- `mix test --app rho_stdlib` passes.
- Targeted LiveView upload tests pass.

## 11. Future Work

- Add pure-Elixir DOCX text extraction.
- Add `read_upload_text` only when general document Q&A is a product need.
- Use `ex_pdf` as a best-effort local PDF preview/verifier if needed.
- Add optional provider/Python fallback only if direct BAML PDF input fails in
  real use.
