# Proficiency-level editing for `edit_row` / `update_cells`

## Problem

Agents can edit top-level skill fields in the `library` data table
(`skill_name`, `skill_description`, etc.) but cannot edit values inside
each skill's nested `proficiency_levels` list (`level`, `level_name`,
`level_description`).

The storage layer already supports nested edits via a `child:<idx>:<field>`
field-path convention in `Rho.Stdlib.DataTable.Table.apply_change/2`
(`apps/rho_stdlib/lib/rho/stdlib/data_table/table.ex:321`). The gap is
entirely in the agent-facing surface: the LLM is never told the format
exists, and several silent-failure modes make it unsafe to expose
without tightening.

## Schema recap

`RhoFrameworks.DataTableSchemas.library_schema/0`
(`apps/rho_frameworks/lib/rho_frameworks/data_table_schemas.ex:16`):

- Top-level columns: `category`, `cluster`, `skill_name`,
  `skill_description`, `_source`, `_reason`.
- `children_key: :proficiency_levels` with `child_columns: [:level,
  :level_name, :level_description]`.

`role_profile_schema/0` is flat (`required_level` is a top-level int)
— that's why `edit_row` already works there.

---

## Phase 1 — Minimal unblocker (documentation only)

Goal: an agent that knows the right field path can edit a proficiency
level. No backend changes.

### 1.1 — Surface the `child:<idx>:<field>` form in `update_cells`

File: `apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex:394`

Update the tool description and `changes_json` doc to mention the
nested form. Keep it short:

```
description: "Update data table cells. Top-level fields: pass the column \
name as `field`. Nested children (e.g. proficiency_levels): use \
`field: \"child:<idx>:<child_field>\"` where idx is the 0-based list \
position. Discover idx by reading the row with query_table (request \
`columns: \"<children_key>\"` since nested lists are elided otherwise)."
```

### 1.2 — Surface child columns in the prompt section

File: `apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex:114`
(`render_columns_line/2`).

When `schema.children_key` is set, append a line like:

```
child columns (proficiency_levels[]): level, level_name, level_description
```

Use `Schema.child_column_names/1` (already exists in
`apps/rho_stdlib/lib/rho/stdlib/data_table/schema.ex:47`).

### 1.3 — Update agent system prompt

File: `.rho.exs` (the `:spreadsheet` agent's `system_prompt`, lines 54–73).

Add to the "Editing tables" block:

> - Nested children (e.g. `proficiency_levels` in `library`): query the
>   row first with `columns: "proficiency_levels"` to find the 0-based
>   index of the target level, then call `update_cells` with
>   `field: "child:<idx>:<child_field>"`.

### 1.4 — Tests

`apps/rho_stdlib/test/rho/stdlib/plugins/data_table_test.exs`:

- `update_cells` with `field: "child:0:level_description"` against a
  library row mutates only the targeted child, leaves siblings intact.
- `edit_row` with `set_field: "child:0:level_description"` does the
  same via the locator path.
- `render_table_index` lists the child columns line when
  `children_key` is set; absent when it isn't.

After Phase 1: a careful agent can edit proficiency levels. Mistakes
still fail silently — see Phase 2.

---

## Phase 2 — Production tightening

Goal: incorrect edits surface as errors instead of `:ok`.

### 2.1 — Validate `child_field` against `child_columns`

File: `apps/rho_stdlib/lib/rho/stdlib/data_table/table.ex:413`
(`update_child_at/7`).

Currently passes `nil` for the schema, so any string becomes a key on
the child map (e.g. `"level_descrption"` typo silently inserts).

Change: resolve `child_field` against `schema.child_columns` (atom-aware,
mirror `resolve_strict_field/2`). On unknown field in `:strict` mode,
return `{:halt, {:error, {:unknown_child_field, child_field,
[available: [...]]}}}`. In dynamic mode, fall through as today.

Threading the `schema` into `update_child_at` is a one-arg signature
change; no callers outside this module.

### 2.2 — Surface bad indices and malformed paths

File: `apps/rho_stdlib/lib/rho/stdlib/data_table/table.ex:393`
(`apply_child_change/4`).

Two silent paths today:

- `["child", idx_str, child_field]` matches but `Integer.parse(idx_str)`
  fails, or the row id doesn't exist, or `children_key` is nil → falls
  through `else _ -> {:cont, {:ok, table}}`.
- `List.update_at(children, idx, fn)` with idx out of range is a no-op.

Change:

- If parse fails or `children_key` is nil for the schema, return
  `{:halt, {:error, {:invalid_child_path, field_path}}}`.
- If idx is negative or `>= length(children)`, return `{:halt,
  {:error, {:child_idx_out_of_range, idx, length: length(children)}}}`.
- If the `field_path` doesn't match the `child:<idx>:<field>` pattern
  but starts with `"child:"`, return `{:halt, {:error,
  {:invalid_child_path, field_path}}}` rather than falling into the
  top-level branch.

### 2.3 — Don't elide the children column when querying for an edit

Optional but high-leverage: `maybe_elide_complex_columns`
(`apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex:315`) replaces
nested lists with `<list<N>>` unless the caller explicitly asks for
the column. The agent will hit this footgun every first attempt.

Two options:

- a. Always include the `children_key` value when present. Cheap row,
     bounded width (≤ 6 levels typically).
- b. Render a compact summary instead of `<list<N>>`, e.g.
     `<proficiency_levels: 0,1,2,3,4>` (the level numbers). Lets the
     agent pick an idx without a second query in most cases.

Pick (b) — keeps the elision discipline for arbitrary lists, gives a
useful hint for the children case specifically.

### 2.4 — Tests

Extend `data_table_test.exs` and `data_table/table_test.exs`:

- Unknown child field in strict mode → `{:error, {:unknown_child_field,
  ...}}`. Dynamic mode still allows it.
- Out-of-range idx → `{:error, {:child_idx_out_of_range, ...}}`.
- Malformed `child:` path → `{:error, {:invalid_child_path, ...}}`.
- `query_table` against a library row shows
  `proficiency_levels: "<proficiency_levels: 0,1,2,3>"` (or similar) by
  default; the full list is returned when `columns: "proficiency_levels"`
  is requested.

---

## Phase 3 — Optional: key-based child addressing

Phase 2 makes positional edits safe. Phase 3 makes them ergonomic when
the natural key (the `level` int 0–5) is what the user is thinking in.

### 3.1 — Accept `child:<key>=<value>:<field>`

File: `apps/rho_stdlib/lib/rho/stdlib/data_table/table.ex:393`.

Extend `apply_child_change/4` to also match
`["child", "level=3", "level_description"]`. Resolve to the first
child whose `<key>` equals `<value>` (string-coerced). If 0 or >1
match, halt with `{:error, {:ambiguous_child_key, ...}}`.

Keep the positional form as-is — it's still the right answer for
unkeyed child rows.

### 3.2 — Doc + prompt update

Mention the keyed form in the same `update_cells` description as
Phase 1.1 once it lands. Encourage `child:level=N:<field>` over
`child:<idx>:<field>` when a natural key exists.

### 3.3 — Tests

- `child:level=3:level_description` finds the matching child and
  updates it.
- Two children with the same level → `{:error, {:ambiguous_child_key,
  ...}}`.
- No matching key → `{:error, {:child_key_not_found, ...}}`.

---

## Out of scope

- Schema-level declaration of a child key (e.g.
  `child_key_fields: [:level]` so we don't have to spell `level=` in
  the path). Worth doing later if multiple domains hit this.
- Editing children of `meta`, `flow:state`, or `research_notes` — none
  of those schemas declare `children_key` today.
- LiveView rendering of nested edits — already works, since the server
  bumps version and broadcasts an invalidation event after
  `update_cells`.

## Suggested ordering

1. Phase 1 (1.1 → 1.2 → 1.3 → 1.4) — small, ships the capability.
2. Phase 2 (2.1 → 2.2 → 2.4) — couple of hours, removes the silent
   failure modes. Do before any agent flow starts relying on it.
3. Phase 2.3 — separate commit, since it touches query rendering.
4. Phase 3 — only if Phase 2 ergonomics turn out to be a real
   irritation in practice.
