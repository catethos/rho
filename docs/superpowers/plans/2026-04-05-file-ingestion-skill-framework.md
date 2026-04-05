# File Ingestion for Skill Framework Editor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the spreadsheet skill framework editor to accept file uploads (Excel, CSV, PDF, images), parse them deterministically in the backend, and let the agent import/reference/enhance frameworks using a single router skill with progressive disclosure.

**Architecture:** One `framework-editor` SKILL.md acts as an intent router, dispatching to reference workflow files loaded on demand via a new `read_resource` tool. File parsing happens async in the backend via Pythonx (openpyxl, pdfplumber, chardet). Parsed data is accessed lazily by the agent via a paginated `get_uploaded_file` tool. SpreadsheetLive gets multi-file upload with multimodal message support.

**Tech Stack:** Elixir/Phoenix LiveView (uploads, async tasks), Python via Pythonx NIF (openpyxl, pdfplumber, chardet), agentskills.io SKILL.md format

**Spec:** `docs/superpowers/specs/2026-04-05-file-ingestion-skill-framework-design.md`

**Elixir/Phoenix conventions:**
- LiveView Iron Laws: no DB queries in disconnected mount, check `connected?/1` before subscriptions, extract variables before closures
- File uploads: use `allow_upload`, `consume_uploaded_entries`, `live_file_input`
- Async work: use `Task.Supervisor.async_nolink`, never block the LiveView process
- All tests: `mix test`, verify with `mix compile --warnings-as-errors`

---

## File Map

### New Files

| File | Responsibility |
|------|---------------|
| `priv/python/file_parser/parse_excel.py` | Parse .xlsx/.csv to JSON (openpyxl + chardet + csv.Sniffer) |
| `priv/python/file_parser/parse_pdf.py` | Parse .pdf to structured rows or text (pdfplumber) |
| `lib/rho/file_parser.ex` | Elixir module routing MIME types to Python parsers |
| `test/rho/file_parser_test.exs` | Unit tests for FileParser |
| `.agents/skills/framework-editor/SKILL.md` | Intent router skill |
| `.agents/skills/framework-editor/references/generate-workflow.md` | Generate from scratch workflow |
| `.agents/skills/framework-editor/references/import-workflow.md` | Import from file workflow |
| `.agents/skills/framework-editor/references/enhance-workflow.md` | Enhance imported data workflow |
| `.agents/skills/framework-editor/references/reference-workflow.md` | Use file as reference workflow |
| `.agents/skills/framework-editor/references/dreyfus-model.md` | Proficiency level definitions |
| `.agents/skills/framework-editor/references/quality-rubric.md` | Behavioral indicator quality rules |
| `.agents/skills/framework-editor/references/column-mapping.md` | Column name aliases + mapping protocol |

### Modified Files

| File | Change |
|------|--------|
| `lib/rho/skills.ex` | Add `read_resource` tool + `default_skills` expansion |
| `lib/rho/config.ex` | Support `default_skills` config field |
| `test/rho/skill_test.exs` | Tests for read_resource + default_skills |
| `lib/rho/mounts/spreadsheet.ex` | Add `get_uploaded_file` tool with pagination |
| `lib/rho_web/live/spreadsheet_live.ex` | Upload pipeline, async parsing, multimodal messages, UI |
| `.rho.exs` | Spreadsheet agent: add `:skills` mount, `default_skills`, `python_deps`, thin prompt |
| `lib/rho_web/inline_css.ex` | Upload UI styling |

---

## Task 1: Python File Parsers

**Files:**
- Create: `priv/python/file_parser/parse_excel.py`
- Create: `priv/python/file_parser/parse_pdf.py`

- [ ] **Step 1: Create priv/python/file_parser/ directory**

Run: `mkdir -p priv/python/file_parser`

- [ ] **Step 2: Write parse_excel.py**

```python
# priv/python/file_parser/parse_excel.py
"""
Parse .xlsx and .csv files into JSON-serializable structures.
Returns a dict with 'sheets' key containing list of sheet objects.
Each sheet: {name, columns, rows, row_count}.

Handles:
- Multi-sheet Excel workbooks
- CSV with auto-detected encoding (chardet) and delimiter (csv.Sniffer)
- UTF-8 BOM, GB2312, Big5, Shift-JIS encodings
"""
import json
import sys
import csv
import io

def parse_xlsx(file_path):
    import openpyxl
    wb = openpyxl.load_workbook(file_path, read_only=True, data_only=True)
    sheets = []
    for sheet_name in wb.sheetnames:
        ws = wb[sheet_name]
        rows_iter = ws.iter_rows(values_only=True)
        try:
            headers = [str(h) if h is not None else f"col_{i}" for i, h in enumerate(next(rows_iter))]
        except StopIteration:
            sheets.append({"name": sheet_name, "columns": [], "rows": [], "row_count": 0})
            continue
        rows = []
        for row in rows_iter:
            row_dict = {}
            for i, val in enumerate(row):
                if i < len(headers):
                    if val is None:
                        row_dict[headers[i]] = ""
                    else:
                        row_dict[headers[i]] = str(val)
            if any(v != "" for v in row_dict.values()):
                rows.append(row_dict)
        sheets.append({
            "name": sheet_name,
            "columns": headers,
            "rows": rows,
            "row_count": len(rows)
        })
    wb.close()
    return {"type": "structured", "sheets": sheets}

def parse_csv(file_path):
    import chardet
    with open(file_path, "rb") as f:
        raw = f.read()
    detected = chardet.detect(raw)
    encoding = detected.get("encoding", "utf-8") or "utf-8"
    text = raw.decode(encoding, errors="replace")
    # Remove BOM if present
    if text.startswith("\ufeff"):
        text = text[1:]
    # Detect delimiter
    try:
        dialect = csv.Sniffer().sniff(text[:4096])
        delimiter = dialect.delimiter
    except csv.Error:
        delimiter = ","
    reader = csv.DictReader(io.StringIO(text), delimiter=delimiter)
    rows = [dict(row) for row in reader]
    columns = reader.fieldnames or []
    return {
        "type": "structured",
        "sheets": [{"name": "Sheet1", "columns": columns, "rows": rows, "row_count": len(rows)}]
    }

def main():
    file_path = sys.argv[1]
    mime_type = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        if mime_type == "text/csv" or file_path.endswith(".csv"):
            result = parse_csv(file_path)
        else:
            result = parse_xlsx(file_path)
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"type": "error", "message": str(e)}))

if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Write parse_pdf.py**

```python
# priv/python/file_parser/parse_pdf.py
"""
Parse PDF files. Two-pass strategy:
1. Try pdfplumber table extraction
2. If clean tables found (>3 cols, >5 rows) → structured output
3. If no clean tables → extract text → unstructured output
4. If no extractable text → error (likely scanned)
"""
import json
import sys

def parse_pdf(file_path):
    import pdfplumber
    pdf = pdfplumber.open(file_path)
    # Pass 1: Try table extraction
    all_rows = []
    columns = None
    for page in pdf.pages:
        tables = page.extract_tables()
        for table in tables:
            if not table or len(table) < 2:
                continue
            if columns is None and len(table[0]) >= 3:
                columns = [str(h) if h else f"col_{i}" for i, h in enumerate(table[0])]
                data_rows = table[1:]
            else:
                data_rows = table
            for row in data_rows:
                if columns and len(row) >= len(columns):
                    row_dict = {columns[i]: str(row[i] or "") for i in range(len(columns))}
                    if any(v != "" for v in row_dict.values()):
                        all_rows.append(row_dict)
    # Decision: structured if we found clean tables
    if columns and len(columns) >= 3 and len(all_rows) >= 5:
        pdf.close()
        return {
            "type": "structured",
            "sheets": [{"name": "PDF Tables", "columns": columns, "rows": all_rows, "row_count": len(all_rows)}]
        }
    # Pass 2: Extract text
    full_text = ""
    for page in pdf.pages:
        text = page.extract_text()
        if text:
            full_text += text + "\n"
    pdf.close()
    full_text = full_text.strip()
    if not full_text:
        return {"type": "error", "message": "Scanned PDF detected. Please upload a digitally-generated PDF or take a screenshot instead."}
    return {"type": "text", "content": full_text, "char_count": len(full_text), "page_count": len(pdf.pages) if hasattr(pdf, 'pages') else 0}

def main():
    file_path = sys.argv[1]
    try:
        result = parse_pdf(file_path)
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"type": "error", "message": str(e)}))

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Manually test with a sample file**

Run: `python3 priv/python/file_parser/parse_excel.py test/fixtures/sample.csv text/csv`
Expected: JSON output with sheets/columns/rows

- [ ] **Step 5: Commit**

```bash
git add priv/python/file_parser/
git commit -m "feat: add Python file parsers for Excel/CSV and PDF"
```

---

## Task 2: Rho.FileParser Elixir Module

**Files:**
- Create: `lib/rho/file_parser.ex`
- Create: `test/rho/file_parser_test.exs`
- Create: `test/fixtures/sample.csv` (test fixture)

- [ ] **Step 1: Create test fixture**

```bash
mkdir -p test/fixtures
```

Write `test/fixtures/sample.csv`:
```csv
Category,Skill,Description
Technical,Python Programming,Ability to write Python code
Technical,Data Analysis,Capability to analyze datasets
Leadership,Team Management,Skill in managing teams
```

- [ ] **Step 2: Write failing tests**

```elixir
# test/rho/file_parser_test.exs
defmodule Rho.FileParserTest do
  use ExUnit.Case, async: true

  alias Rho.FileParser

  describe "parse/2" do
    test "parses CSV file to structured output" do
      path = Path.join([File.cwd!(), "test", "fixtures", "sample.csv"])
      assert {:structured, %{sheets: [sheet]}} = FileParser.parse(path, "text/csv")
      assert sheet.name == "Sheet1"
      assert sheet.row_count == 3
      assert "Category" in sheet.columns
      assert "Skill" in sheet.columns
      assert hd(sheet.rows)["Category"] == "Technical"
    end

    test "parses image to base64" do
      # Create a tiny 1x1 PNG
      png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
              0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0,
              0, 0, 12, 73, 68, 65, 84, 8, 215, 99, 248, 207, 192, 0, 0, 0,
              2, 0, 1, 226, 33, 188, 51, 0, 0, 0, 0, 73, 69, 78, 68, 174,
              66, 96, 130>>
      path = Path.join(System.tmp_dir!(), "test_image_#{System.unique_integer([:positive])}.png")
      File.write!(path, png)

      assert {:image, data, "image/png"} = FileParser.parse(path, "image/png")
      assert is_binary(data)
      assert byte_size(data) > 0

      File.rm(path)
    end

    test "returns error for unsupported file type" do
      path = Path.join(System.tmp_dir!(), "test.xls")
      File.write!(path, "fake content")

      assert {:error, message} = FileParser.parse(path, "application/vnd.ms-excel")
      assert message =~ "Unsupported"

      File.rm(path)
    end
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/rho/file_parser_test.exs`
Expected: FAIL — module `Rho.FileParser` not found

- [ ] **Step 4: Write FileParser module**

```elixir
# lib/rho/file_parser.ex
defmodule Rho.FileParser do
  @moduledoc """
  Parses uploaded files by MIME type. Routes to Python scripts via Pythonx
  for binary formats (Excel, PDF). Handles images natively.

  This is a backend module — it runs in the LiveView process (or a Task),
  not inside the agent loop. The agent never calls this directly.
  """

  require Logger

  @excel_mime "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @csv_mime "text/csv"
  @pdf_mime "application/pdf"

  @type structured_result :: %{
          sheets: [%{name: String.t(), columns: [String.t()], rows: [map()], row_count: integer()}]
        }

  @spec parse(String.t(), String.t()) ::
          {:structured, structured_result()}
          | {:text, String.t()}
          | {:image, binary(), String.t()}
          | {:error, String.t()}

  def parse(path, mime_type) do
    cond do
      mime_type == @excel_mime or String.ends_with?(path, ".xlsx") ->
        parse_with_python(:excel, path, mime_type)

      mime_type == @csv_mime or String.ends_with?(path, ".csv") ->
        parse_with_python(:csv, path, mime_type)

      mime_type == @pdf_mime or String.ends_with?(path, ".pdf") ->
        parse_with_python(:pdf, path, mime_type)

      String.starts_with?(mime_type, "image/") ->
        parse_image(path, mime_type)

      true ->
        ext = Path.extname(path)
        {:error, "Unsupported file type: #{ext}. Supported: .xlsx, .csv, .pdf, .jpg, .png, .webp"}
    end
  end

  defp parse_image(path, media_type) do
    case File.read(path) do
      {:ok, binary} -> {:image, Base64.encode64(binary), media_type}
      {:error, reason} -> {:error, "Failed to read image: #{inspect(reason)}"}
    end
  end

  defp parse_with_python(type, path, mime_type) do
    script = script_for(type)
    args = if type == :pdf, do: [path], else: [path, mime_type]
    code = "exec(open(#{inspect(script)}).read()); main()" |> String.replace("main()", build_main_call(args))

    # Use Pythonx to run the parser script
    python_code = """
    import sys
    sys.argv = #{inspect([script | args])}
    exec(open(#{inspect(script)}).read())
    import json
    _result = main()
    """

    try do
      {result, _} = Pythonx.eval(python_code, %{})
      decoded = Pythonx.decode(result)

      case Jason.decode(decoded) do
        {:ok, %{"type" => "structured", "sheets" => sheets}} ->
          parsed_sheets =
            Enum.map(sheets, fn s ->
              %{
                name: s["name"],
                columns: s["columns"],
                rows: s["rows"],
                row_count: s["row_count"]
              }
            end)
          {:structured, %{sheets: parsed_sheets}}

        {:ok, %{"type" => "text", "content" => content}} ->
          {:text, content}

        {:ok, %{"type" => "error", "message" => message}} ->
          {:error, message}

        {:error, _} ->
          {:error, "Failed to parse Python output"}
      end
    rescue
      e ->
        Logger.error("[FileParser] Python error: #{Exception.message(e)}")
        {:error, "Failed to parse file: #{Exception.message(e)}"}
    end
  end

  defp script_for(:excel), do: script_path("parse_excel.py")
  defp script_for(:csv), do: script_path("parse_excel.py")
  defp script_for(:pdf), do: script_path("parse_pdf.py")

  defp script_path(name) do
    Application.app_dir(:rho, Path.join(["priv", "python", "file_parser", name]))
  end

  defp build_main_call(args) do
    args_str = Enum.map_join(args, ", ", &inspect/1)
    "main()"
  end
end
```

**Note:** The Pythonx integration will need adjustment during implementation — the exact eval pattern depends on how the scripts expose `main()`. The scripts are designed to work as CLI (`sys.argv`) so the simplest approach is to set `sys.argv` and call `main()`, capturing stdout. Adjust the `parse_with_python/3` function to match the actual Pythonx API used in `Rho.Tools.Python.Interpreter`.

- [ ] **Step 5: Run tests**

Run: `mix test test/rho/file_parser_test.exs`
Expected: CSV and image tests PASS. PDF test may need a fixture.

- [ ] **Step 6: Commit**

```bash
git add lib/rho/file_parser.ex test/rho/file_parser_test.exs test/fixtures/sample.csv
git commit -m "feat: add Rho.FileParser module for multi-format file parsing"
```

---

## Task 3: Config — default_skills Support

**Files:**
- Modify: `lib/rho/config.ex`
- Modify: `.rho.exs`

- [ ] **Step 1: Add default_skills to Config.agent/1 output**

In `lib/rho/config.ex`, find the `agent/1` function that builds the agent config map. Add `default_skills` to the parsed fields:

```elixir
# In the agent config building section, add:
default_skills: config[:default_skills] || []
```

- [ ] **Step 2: Add python_deps and default_skills to .rho.exs spreadsheet agent**

In `.rho.exs`, modify the `spreadsheet` agent config:

```elixir
spreadsheet: [
  model: "openrouter:anthropic/claude-sonnet-4.6",
  description: "Skill framework editor with guided intake and parallel generation",
  skills: [],
  python_deps: ["openpyxl", "pdfplumber", "chardet"],
  default_skills: ["framework-editor"],
  system_prompt: """
  You are a skill framework editor assistant.
  Use the framework-editor skill to guide your workflow.
  For simple edits, use spreadsheet tools directly.
  """,
  mounts: [
    :spreadsheet,
    :skills,
    {:multi_agent, only: [:delegate_task, :await_task, :list_agents]}
  ],
  reasoner: :structured,
  max_steps: 50
]
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS, no warnings

- [ ] **Step 4: Commit**

```bash
git add lib/rho/config.ex .rho.exs
git commit -m "feat: add default_skills config and python_deps for spreadsheet agent"
```

---

## Task 4: Skills Mount — read_resource Tool + default_skills Expansion

**Files:**
- Modify: `lib/rho/skills.ex`
- Modify: `test/rho/skill_test.exs`

- [ ] **Step 1: Write failing tests for read_resource**

Add to `test/rho/skill_test.exs`:

```elixir
describe "read_resource tool" do
  setup do
    # Create a temporary skill with a reference file
    skill_dir = Path.join(System.tmp_dir!(), "test_skill_#{System.unique_integer([:positive])}")
    refs_dir = Path.join(skill_dir, "references")
    File.mkdir_p!(refs_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: test-skill
    description: A test skill
    ---
    Test body
    """)

    File.write!(Path.join(refs_dir, "guide.md"), "# Guide\nThis is a reference guide.")

    on_exit(fn -> File.rm_rf!(skill_dir) end)

    %{skill_dir: skill_dir}
  end

  test "reads a resource file from skill directory", %{skill_dir: skill_dir} do
    {:ok, skill} = Rho.Skill.parse_skill_md(Path.join(skill_dir, "SKILL.md"), "test")

    result = Rho.Skills.execute_read_resource(
      %{"skill" => "test-skill", "file" => "references/guide.md"},
      skill_dir,
      [skill]
    )

    assert {:ok, content} = result
    assert content =~ "# Guide"
  end

  test "rejects path traversal", %{skill_dir: skill_dir} do
    {:ok, skill} = Rho.Skill.parse_skill_md(Path.join(skill_dir, "SKILL.md"), "test")

    result = Rho.Skills.execute_read_resource(
      %{"skill" => "test-skill", "file" => "../../etc/passwd"},
      skill_dir,
      [skill]
    )

    assert {:error, "Path traversal denied"} = result
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rho/skill_test.exs`
Expected: FAIL — `execute_read_resource` not defined

- [ ] **Step 3: Add read_resource tool to Rho.Skills**

In `lib/rho/skills.ex`, modify `tools/2` to return both the `skill` tool and the new `read_resource` tool:

```elixir
@impl Rho.Mount
def tools(_mount_opts, %{workspace: workspace} = _context) when is_binary(workspace) do
  skills = Rho.Skill.discover(workspace)
  if skills == [], do: [], else: [skill_tool(workspace, skills), read_resource_tool(workspace, skills)]
end
```

Add the tool definition:

```elixir
defp read_resource_tool(workspace, skills) do
  %{
    tool:
      ReqLLM.tool(
        name: "read_resource",
        description:
          "Read a resource file from a skill's directory. Use when a skill's " <>
            "instructions reference a file in references/ or other subdirectories.",
        parameter_schema: [
          skill: [type: :string, required: true, doc: "The skill name"],
          file: [type: :string, required: true, doc: "Relative path, e.g. 'references/import-workflow.md'"]
        ],
        callback: fn _args -> :ok end
      ),
    execute: fn args -> execute_read_resource(args, workspace, skills) end
  }
end

@doc false
def execute_read_resource(args, _workspace, skills) do
  skill_name = args["skill"] || args[:skill] || ""
  file_path = args["file"] || args[:file] || ""

  if String.trim(skill_name) == "" or String.trim(file_path) == "" do
    {:error, "skill and file are required"}
  else
    case Enum.find(skills, &(String.downcase(&1.name) == String.downcase(skill_name))) do
      nil ->
        available = Enum.map_join(skills, ", ", & &1.name)
        {:ok, "No skill found: \"#{skill_name}\". Available: #{available}"}

      skill ->
        skill_dir = Path.dirname(skill.location)
        resolved = Path.expand(Path.join(skill_dir, file_path))

        if String.starts_with?(resolved, Path.expand(skill_dir)) do
          case File.read(resolved) do
            {:ok, content} -> {:ok, content}
            {:error, _} -> {:error, "File not found: #{file_path}"}
          end
        else
          {:error, "Path traversal denied"}
        end
    end
  end
end
```

- [ ] **Step 4: Add default_skills expansion to prompt_sections**

Modify `prompt_sections/2` in `lib/rho/skills.ex`:

```elixir
@impl Rho.Mount
def prompt_sections(_mount_opts, %{workspace: workspace} = context) when is_binary(workspace) do
  alias Rho.Mount.PromptSection

  skills = Rho.Skill.discover(workspace)

  if skills == [] do
    []
  else
    messages = Map.get(context, :messages)
    # Existing: check user messages for $skill-name hints
    hint_expanded = if messages, do: Rho.Skill.expanded_hints(extract_user_text(messages), skills), else: MapSet.new()

    # New: check default_skills from agent config
    agent_name = Map.get(context, :agent_name)
    default_expanded =
      if agent_name do
        config = Rho.Config.agent(agent_name)
        (config[:default_skills] || []) |> MapSet.new()
      else
        MapSet.new()
      end

    expanded = MapSet.union(hint_expanded, default_expanded)

    [
      %PromptSection{
        key: :skills,
        heading: "Available Skills",
        body: Rho.Skill.render_prompt(skills, expanded),
        kind: :reference,
        priority: :normal
      }
    ]
  end
end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/rho/skill_test.exs`
Expected: PASS

- [ ] **Step 6: Run full test suite**

Run: `mix compile --warnings-as-errors && mix test`
Expected: All tests pass, no warnings

- [ ] **Step 7: Commit**

```bash
git add lib/rho/skills.ex test/rho/skill_test.exs
git commit -m "feat: add read_resource tool and default_skills expansion to Skills mount"
```

---

## Task 5: Spreadsheet Mount — get_uploaded_file Tool

**Files:**
- Modify: `lib/rho/mounts/spreadsheet.ex`

- [ ] **Step 1: Add get_uploaded_file to tools/2**

In `lib/rho/mounts/spreadsheet.ex`, add to the tool list in `tools/2`:

```elixir
@impl Rho.Mount
def tools(_mount_opts, %{session_id: session_id} = context) do
  [
    get_table_tool(session_id),
    get_table_summary_tool(session_id),
    get_uploaded_file_tool(session_id),   # NEW
    update_cells_tool(context),
    add_rows_tool(context),
    add_proficiency_levels_tool(session_id, context),
    delete_rows_tool(context),
    replace_all_tool(context)
  ]
end
```

- [ ] **Step 2: Write the tool definition**

```elixir
defp get_uploaded_file_tool(session_id) do
  %{
    tool:
      ReqLLM.tool(
        name: "get_uploaded_file",
        description:
          "Read parsed content of an uploaded file. For large files (>200 rows), " <>
            "returns first 200 rows by default — use offset/limit to paginate.",
        parameter_schema: [
          filename: [type: :string, required: true, doc: "Filename as shown in the upload summary"],
          sheet: [type: :string, required: false, doc: "Sheet name for multi-sheet Excel. Defaults to first sheet."],
          offset: [type: :integer, required: false, doc: "Start row (0-based). Default: 0"],
          limit: [type: :integer, required: false, doc: "Max rows to return. Default: 200"]
        ],
        callback: fn _args -> :ok end
      ),
    execute: fn args ->
      with_pid(session_id, fn pid ->
        ref = make_ref()
        send(pid, {:get_uploaded_file, {self(), ref}, args})

        receive do
          {^ref, {:ok, data}} -> {:ok, Jason.encode!(data)}
          {^ref, {:error, reason}} -> {:error, reason}
        after
          5_000 -> {:error, "Spreadsheet did not respond in time"}
        end
      end)
    end
  }
end
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS (the LiveView handler for `:get_uploaded_file` will be added in Task 6)

- [ ] **Step 4: Commit**

```bash
git add lib/rho/mounts/spreadsheet.ex
git commit -m "feat: add get_uploaded_file tool with pagination to spreadsheet mount"
```

---

## Task 6: SpreadsheetLive — Upload Pipeline

**Files:**
- Modify: `lib/rho_web/live/spreadsheet_live.ex`

This is the largest task. It adds: `allow_upload`, file entry consumption, async parsing via Task, `parsed_files` storage, summary building, multimodal message assembly, upload UI, and the `handle_info` for `get_uploaded_file`.

- [ ] **Step 1: Add allow_upload and assigns in mount/3**

In `SpreadsheetLive.mount/3`, add after existing assigns:

```elixir
|> assign(:parsed_files, %{})
|> assign(:parsing_files, false)
|> allow_upload(:files,
  accept: ~w(.xlsx .csv .pdf .jpg .jpeg .png .webp),
  max_entries: 10,
  max_file_size: 10_000_000
)
```

- [ ] **Step 2: Modify send_message handler to support files**

Replace the existing `handle_event("send_message", ...)`:

```elixir
def handle_event("send_message", %{"content" => content}, socket) do
  content = String.trim(content)
  has_files = socket.assigns.uploads.files.entries != []

  if content == "" and not has_files do
    {:noreply, socket}
  else
    do_send_with_files(content, socket)
  end
end
```

- [ ] **Step 3: Add do_send_with_files/2 and async parsing**

```elixir
defp do_send_with_files(content, socket) do
  # Consume uploaded entries — copy to stable paths (temp files get cleaned up)
  file_entries =
    consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
      stable_path =
        Path.join(
          System.tmp_dir!(),
          "rho_upload_#{System.unique_integer([:positive])}_#{entry.client_name}"
        )

      File.cp!(path, stable_path)
      {:ok, %{filename: entry.client_name, path: stable_path, mime: entry.client_type}}
    end)

  if file_entries == [] do
    do_send_message(content, socket)
  else
    parent = self()

    Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
      results =
        Enum.map(file_entries, fn entry ->
          result = Rho.FileParser.parse(entry.path, entry.mime)
          File.rm(entry.path)
          %{filename: entry.filename, result: result}
        end)

      send(parent, {:files_parsed, content, results})
    end)

    {:noreply, assign(socket, :parsing_files, true)}
  end
end
```

- [ ] **Step 4: Add handle_info for files_parsed**

```elixir
def handle_info({:files_parsed, content, file_results}, socket) do
  socket = assign(socket, :parsing_files, false)

  # Store parsed data for get_uploaded_file tool
  parsed_files =
    Enum.reduce(file_results, socket.assigns.parsed_files, fn
      %{filename: name, result: {:structured, data}}, acc -> Map.put(acc, name, {:structured, data})
      %{filename: name, result: {:text, text}}, acc -> Map.put(acc, name, {:text, text})
      _, acc -> acc
    end)

  socket = assign(socket, :parsed_files, parsed_files)

  # Build enriched message
  {text_summary, image_parts} = build_file_context(file_results)

  enriched_text =
    if content != "" and text_summary != "" do
      content <> "\n\n" <> text_summary
    else
      content <> text_summary
    end

  submit_content =
    if image_parts != [] do
      text_parts =
        if enriched_text != "",
          do: [ReqLLM.Message.ContentPart.text(enriched_text)],
          else: []

      text_parts ++ image_parts
    else
      enriched_text
    end

  do_send_message(submit_content, socket)
end
```

- [ ] **Step 5: Add file context builder helpers**

```elixir
defp build_file_context(file_results) do
  {summaries, images} =
    Enum.reduce(file_results, {[], []}, fn result, {summ, imgs} ->
      case result do
        %{filename: name, result: {:structured, %{sheets: sheets}}} ->
          sheet_info =
            Enum.map_join(sheets, "\n", fn s ->
              sample =
                s.rows
                |> Enum.take(3)
                |> Enum.with_index(1)
                |> Enum.map_join("\n", fn {row, i} ->
                  "  Row #{i}: #{Jason.encode!(row)}"
                end)

              "  Sheet \"#{s.name}\": #{s.row_count} rows, #{length(s.columns)} columns (#{Enum.join(s.columns, ", ")})\n#{sample}"
            end)

          summary = "- #{name}:\n#{sheet_info}\n  Use get_uploaded_file(\"#{name}\") to read all rows."
          {[summary | summ], imgs}

        %{filename: name, result: {:text, text}} ->
          summary = "- #{name}: Extracted text (#{String.length(text)} chars). Prose content.\n  Use get_uploaded_file(\"#{name}\") to read full text."
          {[summary | summ], imgs}

        %{filename: _name, result: {:image, base64, media_type}} ->
          image_part = ReqLLM.Message.ContentPart.image(Base64.decode64!(base64), media_type)
          {summ, [image_part | imgs]}

        %{filename: name, result: {:error, message}} ->
          summary = "- #{name}: ERROR — #{message}"
          {[summary | summ], imgs}

        _ ->
          {summ, imgs}
      end
    end)

  text =
    if summaries != [] do
      "[Uploaded files]\n" <> Enum.join(Enum.reverse(summaries), "\n")
    else
      ""
    end

  {text, Enum.reverse(images)}
end

defp build_submit_content(content, text_summary, image_parts) do
  enriched_text =
    case {content, text_summary} do
      {"", ""} -> ""
      {c, ""} -> c
      {"", s} -> s
      {c, s} -> c <> "\n\n" <> s
    end

  if image_parts != [] do
    text_parts = if enriched_text != "", do: [ReqLLM.Message.ContentPart.text(enriched_text)], else: []
    text_parts ++ image_parts
  else
    enriched_text
  end
end
```

- [ ] **Step 6: Add handle_info for get_uploaded_file**

```elixir
def handle_info({:get_uploaded_file, {caller_pid, ref}, args}, socket) do
  filename = args["filename"] || ""
  sheet_name = args["sheet"]
  offset = args["offset"] || 0
  limit = args["limit"] || 200

  result =
    case Map.get(socket.assigns.parsed_files, filename) do
      nil ->
        {:error, "No uploaded file found: \"#{filename}\". Available: #{Map.keys(socket.assigns.parsed_files) |> Enum.join(", ")}"}

      {:structured, %{sheets: sheets}} ->
        # Find the requested sheet (default: first)
        sheet =
          if sheet_name do
            Enum.find(sheets, hd(sheets), &(&1.name == sheet_name))
          else
            hd(sheets)
          end

        paginated_rows = sheet.rows |> Enum.drop(offset) |> Enum.take(limit)
        total = sheet.row_count

        {:ok, %{
          name: sheet.name,
          columns: sheet.columns,
          rows: paginated_rows,
          row_count: length(paginated_rows),
          total_rows: total,
          offset: offset,
          has_more: offset + limit < total
        }}

      {:text, text} ->
        {:ok, %{type: "text", content: text, char_count: String.length(text)}}
    end

  send(caller_pid, {ref, result})
  {:noreply, socket}
end
```

- [ ] **Step 7: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add lib/rho_web/live/spreadsheet_live.ex
git commit -m "feat: add file upload pipeline with async parsing to SpreadsheetLive"
```

---

## Task 7: Upload UI

**Files:**
- Modify: `lib/rho_web/live/spreadsheet_live.ex` (render function)
- Modify: `lib/rho_web/inline_css.ex`

- [ ] **Step 1: Add upload UI to render template**

In `SpreadsheetLive.render/1`, replace the chat input area with:

```heex
<div class="chat-input-area">
  <%!-- File chips for selected files --%>
  <div :if={@uploads.files.entries != []} class="file-chips">
    <%= for entry <- @uploads.files.entries do %>
      <div class="file-chip">
        <span class="file-chip-icon"><%= file_type_icon(entry.client_type) %></span>
        <span class="file-chip-name"><%= entry.client_name %></span>
        <span :if={entry.progress > 0 and entry.progress < 100} class="file-chip-progress">
          <%= entry.progress %>%
        </span>
        <button type="button" phx-click="cancel_upload" phx-value-ref={entry.ref} class="file-chip-remove">
          x
        </button>
      </div>
    <% end %>
  </div>

  <%!-- Parsing indicator --%>
  <div :if={@parsing_files} class="parsing-indicator">
    Parsing files...
  </div>

  <form id="chat-input-form" phx-submit="send_message" phx-change="validate_upload" class="chat-input-form">
    <.live_file_input upload={@uploads.files} class="file-input-hidden" />
    <label for={@uploads.files.ref} class="btn-attach" title="Attach files">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M21.44 11.05l-9.19 9.19a6 6 0 01-8.49-8.49l9.19-9.19a4 4 0 015.66 5.66l-9.2 9.19a2 2 0 01-2.83-2.83l8.49-8.48" />
      </svg>
    </label>
    <textarea
      name="content"
      id="chat-input"
      placeholder="Ask to generate skills, import files, edit rows..."
      rows="1"
      phx-hook="AutoResize"
    ></textarea>
    <button type="submit" class="btn-send">Send</button>
  </form>
</div>
```

- [ ] **Step 2: Add cancel_upload and validate_upload events**

```elixir
def handle_event("cancel_upload", %{"ref" => ref}, socket) do
  {:noreply, cancel_upload(socket, :files, ref)}
end

def handle_event("validate_upload", _params, socket) do
  # Check total upload size
  total_size = Enum.reduce(socket.assigns.uploads.files.entries, 0, & &1.client_size + &2)

  socket =
    if total_size > 50_000_000 do
      put_flash(socket, :error, "Total upload size exceeds 50MB. Please upload fewer or smaller files.")
    else
      socket
    end

  {:noreply, socket}
end
```

- [ ] **Step 3: Add file_type_icon helper**

```elixir
defp file_type_icon(mime_type) do
  cond do
    String.contains?(mime_type, "spreadsheet") or String.contains?(mime_type, "csv") -> "XLS"
    String.contains?(mime_type, "pdf") -> "PDF"
    String.starts_with?(mime_type, "image/") -> "IMG"
    true -> "FILE"
  end
end
```

- [ ] **Step 4: Add CSS for upload UI**

In `lib/rho_web/inline_css.ex`, add styles for file chips, attach button, and parsing indicator. The exact CSS should follow the existing spreadsheet panel styling conventions.

- [ ] **Step 5: Verify it renders**

Run: `mix compile --warnings-as-errors`
Then start the server: `mix phx.server`
Navigate to `/sheet/new` and verify the attach button appears.

- [ ] **Step 6: Commit**

```bash
git add lib/rho_web/live/spreadsheet_live.ex lib/rho_web/inline_css.ex
git commit -m "feat: add upload UI with file chips, attach button, and parsing indicator"
```

---

## Task 8: Framework Editor Skill + Reference Files

**Files:**
- Create: `.agents/skills/framework-editor/SKILL.md`
- Create: `.agents/skills/framework-editor/references/generate-workflow.md`
- Create: `.agents/skills/framework-editor/references/import-workflow.md`
- Create: `.agents/skills/framework-editor/references/enhance-workflow.md`
- Create: `.agents/skills/framework-editor/references/reference-workflow.md`
- Create: `.agents/skills/framework-editor/references/dreyfus-model.md`
- Create: `.agents/skills/framework-editor/references/quality-rubric.md`
- Create: `.agents/skills/framework-editor/references/column-mapping.md`

- [ ] **Step 1: Create skill directory**

Run: `mkdir -p .agents/skills/framework-editor/references`

- [ ] **Step 2: Write SKILL.md (the router)**

The SKILL.md body should contain:
- Intent detection table (from spec)
- Shared rules (MECE, Dreyfus default, 6-10 competencies, observable indicators)
- Instructions for when to load each reference file
- File upload handling instructions

Keep under 200 lines / 5000 tokens.

- [ ] **Step 3: Write generate-workflow.md**

Move the current spreadsheet agent's 3-phase system prompt from `.rho.exs` into this file:
- Phase 1: Guided Intake
- Phase 2: Skeleton Generation
- Phase 3: Parallel Proficiency Generation via sub-agents

- [ ] **Step 4: Write import-workflow.md**

Content should cover:
- Reading parsed file data via `get_uploaded_file`
- Column mapping protocol (propose mapping, confirm with user)
- Multi-sheet handling (ask which sheet if multiple)
- Pagination for large files (>200 rows: import in batches)
- Deduplication when spreadsheet already has data

- [ ] **Step 5: Write enhance-workflow.md**

Content should cover:
- Prerequisites: data already in spreadsheet (from import or generation)
- Gap analysis: identify missing proficiency levels, weak descriptions
- Delegate proficiency generation to sub-agents per category
- Quality improvement: strengthen behavioral indicators

- [ ] **Step 6: Write reference-workflow.md**

Content should cover:
- Read uploaded file as context (don't import directly)
- Extract patterns: categories, naming conventions, level structure
- Use patterns to inform new framework generation
- Proceed to generate-workflow after reference analysis

- [ ] **Step 7: Write supporting reference files**

- `dreyfus-model.md`: 5 levels with Bloom's taxonomy verbs (from current proficiency_writer prompt)
- `quality-rubric.md`: Observable behavior rules (from current prompts)
- `column-mapping.md`: Common column name aliases for HR/L&D frameworks, including non-English names (Malay, Chinese)

- [ ] **Step 8: Verify skill discovery**

Run a quick check that the skill is discovered:

```elixir
# In iex -S mix:
Rho.Skill.discover(File.cwd!())
# Should include %Rho.Skill{name: "framework-editor", ...}
```

- [ ] **Step 9: Commit**

```bash
git add .agents/skills/framework-editor/
git commit -m "feat: add framework-editor skill with router and reference workflows"
```

---

## Task 9: Integration Testing

**Files:**
- No new files — verify end-to-end flow

- [ ] **Step 1: Compile and run tests**

Run: `mix compile --warnings-as-errors && mix test`
Expected: All existing tests pass, new tests pass

- [ ] **Step 2: Manual smoke test — upload flow**

1. Start server: `mix phx.server`
2. Navigate to `http://localhost:4001/sheet/new`
3. Click attach button, select a .csv file
4. Verify file chip appears
5. Type "Import this" and click Send
6. Verify "Parsing files..." appears briefly
7. Verify agent receives the upload summary
8. Verify agent activates framework-editor skill and loads import-workflow

- [ ] **Step 3: Manual smoke test — generate flow (regression)**

1. Navigate to `http://localhost:4001/sheet/new`
2. Type "Build a framework for software engineering managers"
3. Verify agent loads framework-editor skill → generate-workflow
4. Verify intake questions, skeleton generation, proficiency delegation all work

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: integration test fixes for file ingestion"
```

---

## Summary

| Task | Component | Est. Complexity |
|------|-----------|----------------|
| 1 | Python file parsers | Medium |
| 2 | Rho.FileParser Elixir module | Medium |
| 3 | Config — default_skills | Small |
| 4 | Skills mount — read_resource + default_skills | Medium |
| 5 | Spreadsheet mount — get_uploaded_file | Small |
| 6 | SpreadsheetLive — upload pipeline | Large |
| 7 | Upload UI | Medium |
| 8 | Skill + reference files | Large (content) |
| 9 | Integration testing | Medium |

**Dependencies:**
- Task 1 → Task 2 (parsers before Elixir wrapper)
- Task 3 → Task 4 (config before skills mount reads it)
- Tasks 2, 4, 5 → Task 6 (all modules before LiveView integrates them)
- Task 6 → Task 7 (pipeline before UI)
- Task 4 → Task 8 (read_resource before skill references can be loaded)
- All → Task 9

**Parallelizable:** Tasks 1+3 can run in parallel. Tasks 4+5 can run in parallel. Task 8 can start as soon as Task 4 is done.
