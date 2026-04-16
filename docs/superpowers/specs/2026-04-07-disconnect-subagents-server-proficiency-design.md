# Disconnect Subagents + Server-Side Proficiency Generation

**Date:** 2026-04-07
**Branch:** `skill_framework`
**Context:** Scenario 2 testing revealed data_extractor subagent causing Finch pool exhaustion and incorrect delegation. Both subagents (data_extractor, proficiency_writer) are either dead code or replaceable.

---

## Problem

1. **data_extractor is dead code** — FSF is already in the DB, backend parsing handles normal uploads. The subagent was FSF-specific.
2. **proficiency_writer causes Finch pool exhaustion** — subagent + main agent compete for Finch connections, causing RuntimeError crashes.
3. **Agent mis-delegates** — framework-editor delegates consolidation/merge tasks to data_extractor, which is wrong. The SKILL.md intent detection doesn't cover "consolidate" as a direct-edit intent.

## Solution

Remove multi-agent delegation from the spreadsheet agent entirely. Replace proficiency generation with a server-side tool that fans out parallel LLM calls internally.

---

## Changes

### 1. Remove `multi_agent` mount from spreadsheet agent

**File:** `.rho.exs`

Remove `{:multi_agent, only: [:delegate_task, :await_task, :list_agents]}` from the spreadsheet agent's mounts list. The agent loses `delegate_task`, `await_task`, `list_agents` tools.

### 2. Comment out `data_extractor` agent config

**File:** `.rho.exs`

Comment out the `data_extractor` block (not delete — user wants to redesign it as a coding agent later).

### 3. New tool: `generate_proficiency_levels`

**File:** `lib/rho/mounts/spreadsheet.ex`

Replaces the current `add_proficiency_levels` tool. Instead of the agent generating all proficiency text and passing it in, the agent passes a list of skills and the tool handles LLM generation internally.

**Interface:**
```
generate_proficiency_levels(
  skills_json: "[{\"skill_name\": \"SQL\", \"category\": \"Data\", \"cluster\": \"Wrangling\", \"skill_description\": \"...\", \"role\": \"Data Scientist\"}]"
)
```

**Internal behavior:**
1. Parse the skills list from JSON
2. Group skills into batches (e.g., by category, or chunks of 5-8 skills)
3. For each batch, spawn a `Task.async` that:
   a. Calls `gpt-oss-120b` via `ReqLLM` with the Dreyfus prompt + skill list
   b. Parses the response into rows
   c. Sends rows to the spreadsheet LiveView process via `stream_rows_progressive`
4. `Task.await_many` all batches (with timeout)
5. Return summary: "Generated N proficiency levels for M skills"

**Model config:** `openrouter:openai/gpt-oss-120b` — hardcoded in the tool or read from `.rho.exs` spreadsheet agent config (e.g., `proficiency_model` key).

**Finch isolation:** The parallel LLM calls happen while the main agent is idle (waiting for tool result). No Finch contention because the main agent isn't streaming at the same time.

**Keep `add_proficiency_levels` as-is** — it's still useful as a manual/direct tool if the agent wants to pass pre-generated levels. The new tool is for the "generate from scratch" case.

### 4. Dreyfus prompt as reference doc

**File:** `.agents/skills/framework-editor/references/proficiency-levels.md`

Extract the Dreyfus model prompt from the current `proficiency_writer` system prompt in `.rho.exs`. This serves dual purpose:
- The `generate_proficiency_levels` tool uses it as the LLM system prompt
- The main agent can `read_resource` it for context when discussing proficiency levels with the user

**Content:** The Dreyfus level definitions, quality rules, and output format from the current proficiency_writer system prompt (lines 75-136 of `.rho.exs`).

### 5. Update SKILL.md

**File:** `.agents/skills/framework-editor/SKILL.md`

- Remove all delegation rules (no more "delegate to data_extractor" or "delegate to proficiency_writer")
- Remove `delegate_task` / `await_task` from tool references
- Add "Consolidate/Merge roles" as a direct-edit intent (use spreadsheet tools: delete_rows, update_cells, add_rows)
- Add "Generate proficiency levels" intent pointing to `generate_proficiency_levels` tool
- Update Phase 3 of generate-workflow to use `generate_proficiency_levels` instead of delegation

---

## What stays unchanged

- `add_proficiency_levels` tool — still available for manual/direct level insertion
- `import_from_file` tool — still available (backend file parsing uses it)
- `proficiency_writer` config in `.rho.exs` — comment out alongside data_extractor
- All other spreadsheet tools and framework browsing tools

## Risk

- **Batch size tuning** — if we send too many skills per LLM call, the response may be too large or slow. Start with 5-8 skills per batch, tune based on testing.
- **gpt-oss-120b quality** — need to verify proficiency level quality is comparable to deepseek-chat-v3.1. If not, model is configurable.
- **Timeout** — parallel tasks need a reasonable timeout (60s per batch). If one batch fails, others should still succeed.
