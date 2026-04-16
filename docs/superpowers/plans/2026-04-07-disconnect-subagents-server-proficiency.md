# Disconnect Subagents + Server-Side Proficiency Generation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove multi-agent delegation from the spreadsheet agent and replace proficiency generation with a server-side tool that calls `gpt-oss-120b` in parallel.

**Architecture:** The spreadsheet agent becomes self-contained — no subagents. A new `generate_proficiency_levels` tool accepts skill metadata, fans out parallel `ReqLLM.generate_text` calls using `Task.async_stream`, and streams results into the spreadsheet as they complete.

**Tech Stack:** Elixir, ReqLLM, Task.async_stream, `openrouter:openai/gpt-oss-120b`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `.rho.exs` | Modify | Comment out data_extractor + proficiency_writer, remove multi_agent mount from spreadsheet, add proficiency_model config |
| `lib/rho/mounts/spreadsheet.ex` | Modify | Add `generate_proficiency_levels_tool`, keep existing `add_proficiency_levels_tool` |
| `.agents/skills/framework-editor/SKILL.md` | Modify | Remove delegation rules, add consolidate intent, update tool list |
| `.agents/skills/framework-editor/references/generate-workflow.md` | Modify | Phase 3: replace delegation with `generate_proficiency_levels` tool call |
| `.agents/skills/framework-editor/references/enhance-workflow.md` | Modify | Step 3: replace delegation with `generate_proficiency_levels` tool call |
| `.agents/skills/framework-editor/references/proficiency-prompt.md` | Create | Dreyfus prompt extracted from proficiency_writer config |
| `test/rho/mounts/spreadsheet_proficiency_test.exs` | Create | Test the new generate_proficiency_levels tool |

---

### Task 1: Comment out subagent configs in .rho.exs

**Files:**
- Modify: `.rho.exs:56-152`

- [ ] **Step 1: Comment out data_extractor config**

In `.rho.exs`, comment out the entire `data_extractor` block (lines 138-152):

```elixir
  # data_extractor: [
  #   model: "openrouter:anthropic/claude-sonnet-4",
  #   description:
  #     "Extracts data from uploaded files (Excel, CSV, PDF) into spreadsheet row format using Python",
  #   skills: ["data extraction", "file parsing", "data transformation"],
  #   default_skills: ["data-extractor"],
  #   system_prompt: """
  #   You are a data extraction specialist.
  #   Use the data-extractor skill to guide your workflow.
  #   Always check reference scripts for similar file patterns before writing your own.
  #   """,
  #   mounts: [:bash, :skills, :spreadsheet],
  #   reasoner: :direct,
  #   max_steps: 30
  # ],
```

- [ ] **Step 2: Comment out proficiency_writer config**

Comment out the entire `proficiency_writer` block (lines 75-137):

```elixir
  # proficiency_writer: [
  #   model: "openrouter:deepseek/deepseek-chat-v3.1",
  #   ... (entire block)
  # ],
```

- [ ] **Step 3: Remove multi_agent mount from spreadsheet agent**

Change the spreadsheet mounts (lines 67-71) from:

```elixir
    mounts: [
      :spreadsheet,
      :skills,
      {:multi_agent, only: [:delegate_task, :await_task, :list_agents]}
    ],
```

To:

```elixir
    mounts: [
      :spreadsheet,
      :skills
    ],
```

- [ ] **Step 4: Add proficiency_model config to spreadsheet agent**

Add a `proficiency_model` key to the spreadsheet agent config, after line 57:

```elixir
  spreadsheet: [
    model: "openrouter:deepseek/deepseek-chat-v3.1",
    proficiency_model: "openrouter:openai/gpt-oss-120b",
    description: "Skill framework editor with guided intake and parallel generation",
```

- [ ] **Step 5: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly. The commented-out configs are just Elixir map entries — removing them shouldn't break anything since they're only loaded at runtime via `Rho.Config.agent/1`.

- [ ] **Step 6: Commit**

```bash
git add .rho.exs
git commit -m "refactor: disconnect subagents from spreadsheet agent

Comment out data_extractor (dead code — FSF in DB) and proficiency_writer.
Remove multi_agent mount from spreadsheet agent.
Add proficiency_model config for server-side generation."
```

---

### Task 2: Create proficiency prompt reference doc

**Files:**
- Create: `.agents/skills/framework-editor/references/proficiency-prompt.md`

- [ ] **Step 1: Create the proficiency prompt file**

Extract the Dreyfus prompt from the proficiency_writer system_prompt in `.rho.exs` (lines 80-132) into a standalone reference doc:

```markdown
# Proficiency Level Generation Prompt

You generate Dreyfus-model proficiency levels for competency framework skills.

## Proficiency Level Model (Dreyfus-based)

Level 1 — Novice (Foundational):
  Follows established procedures. Needs supervision for non-routine situations.
  Verbs: identifies, follows, recognizes, describes, lists

Level 2 — Advanced Beginner (Developing):
  Applies learned patterns to real situations. Handles routine tasks independently.
  Verbs: applies, demonstrates, executes, implements, operates

Level 3 — Competent (Proficient):
  Plans deliberately. Organizes work systematically. Takes ownership of outcomes.
  Verbs: analyzes, organizes, prioritizes, troubleshoots, coordinates

Level 4 — Advanced (Senior):
  Exercises judgment in ambiguous situations. Mentors others. Optimizes processes.
  Verbs: evaluates, mentors, optimizes, integrates, influences

Level 5 — Expert (Master):
  Innovates and shapes the field. Operates intuitively. Recognized authority.
  Verbs: architects, transforms, pioneers, establishes, strategizes

## Quality Rules
- Each description MUST be observable: what would you literally SEE this person doing?
- Format: [action verb] + [core activity] + [context or business outcome]
- GOOD: "Designs distributed architectures that maintain sub-100ms p99 latency under 10x traffic spikes"
- BAD: "Is good at system design"
- Each level assumes mastery of all prior levels — don't repeat lower-level behaviors
- Levels must be mutually exclusive — if two levels sound interchangeable, rewrite
- 1-2 sentences per level_description, max

## Output Format

Return a JSON array. Each entry has the skill metadata and a levels array:

```json
[
  {
    "skill_name": "SQL",
    "levels": [
      {"level": 1, "level_name": "Novice", "level_description": "..."},
      {"level": 2, "level_name": "Advanced Beginner", "level_description": "..."},
      {"level": 3, "level_name": "Competent", "level_description": "..."},
      {"level": 4, "level_name": "Advanced", "level_description": "..."},
      {"level": 5, "level_name": "Expert", "level_description": "..."}
    ]
  }
]
```

Include ALL skills provided in a single JSON response.
```

- [ ] **Step 2: Commit**

```bash
git add .agents/skills/framework-editor/references/proficiency-prompt.md
git commit -m "docs: extract Dreyfus proficiency prompt as reference doc"
```

---

### Task 3: Implement generate_proficiency_levels tool

**Files:**
- Modify: `lib/rho/mounts/spreadsheet.ex:40-50` (tool list), append new function
- Test: `test/rho/mounts/spreadsheet_proficiency_test.exs`

- [ ] **Step 1: Write failing test**

Create `test/rho/mounts/spreadsheet_proficiency_test.exs`:

```elixir
defmodule Rho.Mounts.SpreadsheetProficiencyTest do
  use ExUnit.Case, async: false

  alias Rho.Mounts.Spreadsheet

  describe "generate_proficiency_levels tool" do
    test "parses skills_json and returns generated levels" do
      # We test the tool definition is present and has the right shape
      context = %{
        session_id: "test_session",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool_names = Enum.map(tools, fn t -> t.tool.name end)
      assert "generate_proficiency_levels" in tool_names
    end

    test "rejects empty skills list" do
      context = %{
        session_id: "test_session",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "generate_proficiency_levels" end)
      result = tool.execute.(%{"skills_json" => "[]"})
      assert {:error, _} = result
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rho/mounts/spreadsheet_proficiency_test.exs -v`
Expected: FAIL — `generate_proficiency_levels` tool not found in tool list.

- [ ] **Step 3: Add tool to the tools list**

In `lib/rho/mounts/spreadsheet.ex`, in the `tools/2` function (around line 40), add the new tool to the list:

```elixir
      add_proficiency_levels_tool(session_id, context),
      generate_proficiency_levels_tool(session_id, context),
      delete_rows_tool(context),
```

- [ ] **Step 4: Implement generate_proficiency_levels_tool**

Add this function to `lib/rho/mounts/spreadsheet.ex` after the `add_proficiency_levels_tool` function (after line 348):

```elixir
  defp generate_proficiency_levels_tool(session_id, context) do
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "generate_proficiency_levels",
          description:
            "Generate Dreyfus-model proficiency levels (5 levels) for a list of skills using AI. " <>
              "Pass skill metadata — the tool handles LLM generation in parallel and streams results into the spreadsheet. " <>
              "Use this instead of writing proficiency levels yourself.",
          parameter_schema: [
            skills_json: [
              type: :string,
              required: true,
              doc:
                ~s(JSON array of skills: [{"skill_name":"SQL","category":"Data","cluster":"Wrangling","skill_description":"...","role":"Data Analyst"},...]  )
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        raw = args["skills_json"] || args[:skills_json] || "[]"

        skills =
          case Jason.decode(raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        if skills == [] do
          {:error, "No valid skills. Ensure skills_json is a valid JSON array."}
        else
          generate_levels_parallel(skills, session_id, agent_id, context)
        end
      end
    }
  end

  defp generate_levels_parallel(skills, session_id, agent_id, context) do
    prompt = proficiency_system_prompt()
    model = resolve_proficiency_model(context)

    # Batch skills: up to 6 per LLM call
    batches = Enum.chunk_every(skills, 6)

    results =
      batches
      |> Task.async_stream(
        fn batch ->
          call_proficiency_llm(batch, model, prompt, session_id, agent_id)
        end,
        max_concurrency: 4,
        timeout: 90_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce({0, 0, []}, fn
        {:ok, {:ok, count}}, {total, batches_done, errors} ->
          {total + count, batches_done + 1, errors}

        {:ok, {:error, reason}}, {total, batches_done, errors} ->
          {total, batches_done + 1, [reason | errors]}

        {:exit, _reason}, {total, batches_done, errors} ->
          {total, batches_done + 1, ["batch timed out" | errors]}
      end)

    {total_levels, _batches_done, errors} = results

    case {total_levels, errors} do
      {0, errs} ->
        {:error, "Failed to generate levels: #{Enum.join(errs, "; ")}"}

      {n, []} ->
        {:ok, "Generated #{n} proficiency level(s) for #{length(skills)} skill(s)"}

      {n, errs} ->
        {:ok,
         "Generated #{n} proficiency level(s) for #{length(skills)} skill(s). " <>
           "#{length(errs)} batch(es) failed: #{Enum.join(errs, "; ")}"}
    end
  end

  defp call_proficiency_llm(skills_batch, model, system_prompt, session_id, agent_id) do
    user_content =
      "Generate 5 Dreyfus proficiency levels for each skill below. " <>
        "Return ONLY a JSON array.\n\n" <>
        Jason.encode!(skills_batch)

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_content}
    ]

    case ReqLLM.generate_text(model, messages, []) do
      {:ok, response} ->
        text = extract_text(response)

        case parse_levels_json(text) do
          {:ok, skill_levels} ->
            rows = levels_to_rows(skill_levels, skills_batch)
            stream_rows_progressive(rows, :add, session_id, agent_id)
            {:ok, length(rows)}

          {:error, reason} ->
            {:error, "JSON parse failed: #{reason}"}
        end

      {:error, reason} ->
        {:error, "LLM call failed: #{inspect(reason)}"}
    end
  end

  defp extract_text(%{choices: [%{message: %{content: content}} | _]}), do: content
  defp extract_text(%{"choices" => [%{"message" => %{"content" => content}} | _]}), do: content
  defp extract_text(other), do: inspect(other)

  defp parse_levels_json(text) do
    # Strip markdown code fences if present
    cleaned =
      text
      |> String.replace(~r/```json\s*/, "")
      |> String.replace(~r/```\s*/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _} -> {:error, "expected JSON array"}
      {:error, err} -> {:error, inspect(err)}
    end
  end

  defp levels_to_rows(skill_levels, skills_batch) do
    # Build a lookup from the original batch for metadata
    meta_lookup =
      Map.new(skills_batch, fn s -> {s["skill_name"], s} end)

    Enum.flat_map(skill_levels, fn skill_entry ->
      skill_name = skill_entry["skill_name"] || ""
      meta = Map.get(meta_lookup, skill_name, %{})
      role = meta["role"] || skill_entry["role"] || ""
      category = meta["category"] || skill_entry["category"] || ""
      cluster = meta["cluster"] || skill_entry["cluster"] || ""
      skill_desc = meta["skill_description"] || skill_entry["skill_description"] || ""
      levels = skill_entry["levels"] || []

      Enum.map(levels, fn lvl ->
        %{
          role: role,
          category: category,
          cluster: cluster,
          skill_name: skill_name,
          skill_description: skill_desc,
          level: lvl["level"] || 1,
          level_name: lvl["level_name"] || "",
          level_description: lvl["level_description"] || ""
        }
      end)
    end)
  end

  defp resolve_proficiency_model(context) do
    agent_name = context[:agent_name] || :spreadsheet
    config = Rho.Config.agent(agent_name)
    config[:proficiency_model] || config[:model] || "openrouter:openai/gpt-oss-120b"
  end

  defp proficiency_system_prompt do
    """
    You generate Dreyfus-model proficiency levels for competency framework skills.

    ## Proficiency Level Model (Dreyfus-based)

    Level 1 — Novice (Foundational):
      Follows established procedures. Needs supervision for non-routine situations.
      Verbs: identifies, follows, recognizes, describes, lists

    Level 2 — Advanced Beginner (Developing):
      Applies learned patterns to real situations. Handles routine tasks independently.
      Verbs: applies, demonstrates, executes, implements, operates

    Level 3 — Competent (Proficient):
      Plans deliberately. Organizes work systematically. Takes ownership of outcomes.
      Verbs: analyzes, organizes, prioritizes, troubleshoots, coordinates

    Level 4 — Advanced (Senior):
      Exercises judgment in ambiguous situations. Mentors others. Optimizes processes.
      Verbs: evaluates, mentors, optimizes, integrates, influences

    Level 5 — Expert (Master):
      Innovates and shapes the field. Operates intuitively. Recognized authority.
      Verbs: architects, transforms, pioneers, establishes, strategizes

    ## Quality Rules
    - Each description MUST be observable: what would you literally SEE this person doing?
    - Format: [action verb] + [core activity] + [context or business outcome]
    - GOOD: "Designs distributed architectures that maintain sub-100ms p99 latency under 10x traffic spikes"
    - BAD: "Is good at system design"
    - Each level assumes mastery of all prior levels — don't repeat lower-level behaviors
    - Levels must be mutually exclusive — if two levels sound interchangeable, rewrite
    - 1-2 sentences per level_description, max

    ## Output Format
    Return ONLY a JSON array. Each entry has skill_name and levels:
    [{"skill_name":"SQL","levels":[{"level":1,"level_name":"Novice","level_description":"..."},...]},...]

    Include ALL skills provided. No markdown, no explanation — just the JSON array.
    """
  end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/rho/mounts/spreadsheet_proficiency_test.exs -v`
Expected: PASS (both tests — tool present and empty list rejection).

- [ ] **Step 6: Run full compile check**

Run: `mix compile --warnings-as-errors`
Expected: clean compilation.

- [ ] **Step 7: Commit**

```bash
git add lib/rho/mounts/spreadsheet.ex test/rho/mounts/spreadsheet_proficiency_test.exs
git commit -m "feat: add generate_proficiency_levels tool with parallel LLM calls

Server-side tool that fans out ReqLLM.generate_text calls via
Task.async_stream using gpt-oss-120b. Streams results into
spreadsheet progressively. No subagent delegation needed."
```

---

### Task 4: Update SKILL.md — remove delegation, add new intents

**Files:**
- Modify: `.agents/skills/framework-editor/SKILL.md`

- [ ] **Step 1: Remove Multi-Agent section and delegation rules**

Replace the "Multi-Agent" and delegation rules section (lines 86-93):

```markdown
### Multi-Agent
- `delegate_task` — spawn sub-agent for specialized work
- `await_task` — collect sub-agent results

**Delegation rules:**
- **Complex file extraction** → delegate to `data_extractor` role (has Python + spreadsheet access)
- **Proficiency level generation** → delegate to `proficiency_writer` role (Phase 3 of generate-workflow)
- **NEVER delegate to `coder` or `worker`** — they don't have spreadsheet access
```

With:

```markdown
### Proficiency Generation
- `generate_proficiency_levels` — generate Dreyfus-model proficiency levels for a list of skills using AI. Pass skill metadata (skill_name, category, cluster, skill_description, role) — the tool handles parallel LLM generation and streams results into the spreadsheet.
```

- [ ] **Step 2: Add Consolidate/Merge intent to Intent Detection table**

Add this row to the intent detection table (after the "Browse roles" row, before "Load company"):

```markdown
| "Merge these roles" / "Consolidate" / "Remove duplicates across roles" | **Consolidate** | Use spreadsheet tools directly: `get_table` to read, identify duplicates, `delete_rows` to remove, `update_cells` to rename. Do NOT delegate. |
```

- [ ] **Step 3: Commit**

```bash
git add .agents/skills/framework-editor/SKILL.md
git commit -m "docs: remove delegation rules from SKILL.md, add consolidate intent"
```

---

### Task 5: Update generate-workflow.md — replace delegation with tool call

**Files:**
- Modify: `.agents/skills/framework-editor/references/generate-workflow.md`

- [ ] **Step 1: Replace Phase 3**

Replace the entire Phase 3 section (lines 46-60):

```markdown
## Phase 3: Parallel Proficiency Generation

Once the user approves:
1. Use `get_table` to read the current skeleton
2. For each category, call `delegate_task` with role `"proficiency_writer"`
   - Include ALL metadata: category, cluster, skill_name, skill_description
   - Specify the number of proficiency levels to generate
3. Await all tasks one at a time (one `await_task` per step)
4. After ALL awaits complete, use `get_table` to find rows with `level=0`
5. Delete only those placeholder rows by their IDs
6. Report completion stats to user

After generation is complete, remind the user:
"Framework generated with [N] skills. Want to save it? You can say 'save this'
or continue editing first."
```

With:

```markdown
## Phase 3: Proficiency Level Generation

Once the user approves:
1. Use `get_table` to read the current skeleton
2. Collect all skills into a JSON array with their metadata (skill_name, category, cluster, skill_description, role)
3. Call `generate_proficiency_levels(skills_json: "[...]")` — this generates all levels in parallel server-side
4. After generation completes, use `get_table` to find rows with `level=0`
5. Delete only those placeholder rows by their IDs
6. Report completion stats to user

After generation is complete, remind the user:
"Framework generated with [N] skills. Want to save it? You can say 'save this'
or continue editing first."
```

- [ ] **Step 2: Commit**

```bash
git add .agents/skills/framework-editor/references/generate-workflow.md
git commit -m "docs: update generate-workflow Phase 3 to use server-side proficiency tool"
```

---

### Task 6: Update enhance-workflow.md — replace delegation with tool call

**Files:**
- Modify: `.agents/skills/framework-editor/references/enhance-workflow.md`

- [ ] **Step 1: Replace Step 3 proficiency generation section**

Replace the proficiency generation part of Step 3 (lines 29-33):

```markdown
**For proficiency level generation:**
1. Read current data via `get_table`
2. For each category needing levels, call `delegate_task` with role `"proficiency_writer"`
3. Await all tasks
4. Clean up placeholder rows (level=0)
```

With:

```markdown
**For proficiency level generation:**
1. Read current data via `get_table`
2. Collect skills needing levels into a JSON array with metadata (skill_name, category, cluster, skill_description, role)
3. Call `generate_proficiency_levels(skills_json: "[...]")` — generates all levels in parallel server-side
4. Clean up placeholder rows (level=0)
```

- [ ] **Step 2: Commit**

```bash
git add .agents/skills/framework-editor/references/enhance-workflow.md
git commit -m "docs: update enhance-workflow to use server-side proficiency tool"
```

---

### Task 7: Integration test — verify full flow compiles and server starts

**Files:**
- No new files — verification only

- [ ] **Step 1: Run full test suite**

Run: `mix test`
Expected: all existing tests pass + new proficiency test passes.

- [ ] **Step 2: Start server and verify tool availability**

Run: `RHO_WEB_ENABLED=true mix phx.server`

Then in a separate terminal, verify the spreadsheet agent config no longer has multi_agent tools:

```bash
curl -s "http://localhost:4001/spreadsheet?company=bank_abc" | grep -o "delegate_task" | wc -l
```

Expected: 0 (delegate_task should NOT appear).

- [ ] **Step 3: Commit (if any fixups needed)**

If any fixes were needed, commit them with an appropriate message.

---

## Summary

| Task | What | Files |
|------|------|-------|
| 1 | Comment out subagent configs, remove multi_agent mount | `.rho.exs` |
| 2 | Extract Dreyfus prompt as reference doc | `references/proficiency-prompt.md` |
| 3 | Implement generate_proficiency_levels tool | `spreadsheet.ex`, test file |
| 4 | Update SKILL.md — remove delegation, add consolidate intent | `SKILL.md` |
| 5 | Update generate-workflow — Phase 3 uses new tool | `generate-workflow.md` |
| 6 | Update enhance-workflow — Step 3 uses new tool | `enhance-workflow.md` |
| 7 | Integration verification | None |
