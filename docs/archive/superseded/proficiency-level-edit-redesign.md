# Proficiency-level editing — first-principles redesign

> Supersedes `proficiency-level-edit-plan.md` (kept for reference).
> Written assuming we're willing to break existing code if the
> resulting design is meaningfully cleaner.

## What's actually wrong

The bug isn't "the LLM doesn't know about `child:<idx>:<field>`." That's
a symptom. The bug is that **children are addressed positionally, by list
index, with no natural-key alternative**. Everything else in this system
(skills, roles, framework metadata) is addressed by natural keys
(`skill_name`, `level`, `flow_id`, …) declared on the schema. Children
are the one exception — and they're the one place editing breaks down.

Position is the wrong primitive because:

- It isn't stable. Delete one level, every subsequent index shifts.
- It isn't human. The user thinks "level 3 of Python", not "the second
  element of Python's children".
- It can't be validated. "Is idx 5 a real level?" requires runtime
  context the schema doesn't carry.
- It can't be queried. There's no way to filter "the level=3 entry"
  through the existing locator.

Patching this with documentation, as the prior plan proposed, only
makes a fundamentally awkward primitive easier to invoke. The real fix
is to give children the same identity story everything else has.

## Design options considered

### Option A — Children are first-class rows of the parent

Keep the nested storage shape. Give each child a stable identity (a
declared `child_key_fields` like `[:level]`). All addressing — query,
edit, delete — goes through that key. The `child:<idx>:<field>`
syntax disappears entirely. So does the `children_key`-as-magic-string
escape hatch.

### Option B — Split children into their own flat table

Drop `children_key` / `child_columns` from `Schema`. Model `library`
and `library_proficiency_levels` as two tables joined by FK. Standard
relational shape, uniform tools, cascade rules.

### Option C — Virtual flattened view over nested storage

Storage stays nested. The DataTable layer projects a flat view
(`library_proficiency_levels`) that reads from and writes back to
`library.proficiency_levels`. Best of both worlds, at the cost of a
projection layer.

## Recommendation: Option A

The data really is hierarchical: a proficiency level has no meaning
outside its skill, isn't queried across skills, and is read/written
atomically with its parent. The DB schema (`{:array, :map}` embedded)
made the right call. The mistake was at the *agent surface*, not the
storage model.

Option B trades one ad-hoc concept (`children_key`) for two new
ones (FK declarations, cascade rules) — which we'd have to invent
anyway, since the data is composed-not-related. Option C is elegant
but solves a problem we don't have (we don't need both views).

Option A wins because it takes what's already there and makes it
boring: children are rows, rows have keys, keys are how you address
rows. Same primitives end-to-end.

## The redesign

### Schema gains `child_key_fields`

```elixir
%Schema{
  name: "library",
  mode: :strict,
  columns: [
    %Column{name: :category, type: :string, required?: true},
    %Column{name: :skill_name, type: :string, required?: true},
    ...
  ],
  key_fields: [:skill_name],

  children_key: :proficiency_levels,
  child_columns: [
    %Column{name: :level, type: :integer, required?: true},
    %Column{name: :level_name, type: :string},
    %Column{name: :level_description, type: :string}
  ],
  child_key_fields: [:level]   # <-- new; required when children_key is set
}
```

Migration rule: any schema that declares `children_key` MUST declare
`child_key_fields`. Validated at schema construction. No unkeyed
children — that was the whole problem.

### Children carry stable ids

`Table.add_rows/3` and `replace_all/3` mint a stable child id from
the child's key fields when inserting a parent row. The child row
keeps its identity across reorders and parent-row updates. The id
shape is internal — agents and users never see it; they always
address children by natural key.

### Locator: one shape, two levels

The agent locates a child the same way it locates a parent — with
fields. We extend `edit_row` (and the other locator-based tools) with
optional `child_match_*` params:

```
edit_row(
  table: "library",
  match_field: "skill_name", match_value: "Python",
  child_match_field: "level", child_match_value: "3",
  set_field: "level_description",
  set_value: "..."
)
```

Semantics:

- Parent locator (`match_*`) selects exactly one parent row, as
  today.
- If `child_match_*` is given, it must select exactly one child of
  that parent (using `child_key_fields`).
- `set_field` / `set_value` then apply to whichever was selected
  (parent or child), validated against that level's schema columns.
- Errors are loud:
  `{:error, {:no_match, ...}}`, `{:error, {:ambiguous_match, ...}}`,
  `{:error, {:unknown_field, ...}}`, `{:error, {:unknown_child_field,
  ...}}` — the same error shape we already use for parent rows.

### `update_cells` follows the same shape

```json
{
  "id": "<parent_row_id>",
  "child_key": {"level": 3},
  "field": "level_description",
  "value": "..."
}
```

Or, when not editing a child:

```json
{"id": "<parent_row_id>", "field": "skill_name", "value": "Python"}
```

The `child:<idx>:<field>` magic string is removed. There's no
positional addressing path in the public API at all.

### `query_table` shows the children

`maybe_elide_complex_columns` stops being clever about
`children_key`. When a row is returned and its schema declares
children, the children are included by default — they're rows, not
opaque blobs. (For schemas without `children_key`, lists/maps still
elide as today.)

This costs a few tokens per row; it buys the agent zero-round-trip
edits ("I see Python has levels 1–5, let me edit level 3 directly").

### What this lets us delete

- `apply_child_change/4` (`table.ex:393`).
- The `child:<idx>:<field>` parsing branch in `apply_change/2`.
- `update_child_at/7` and its `nil`-schema field resolution.
- The "elide proficiency_levels" carve-out in
  `maybe_elide_complex_columns`.
- The `Editing tables` paragraph in `.rho.exs` that tells the agent
  to use update_cells with positional indices (it never has, because
  it doesn't know how — but the docs alluded to it).

That's a net subtraction. The codebase shrinks.

## What breaks

This is intentional churn — list it explicitly so we don't pretend it's
free.

1. **`Rho.Stdlib.DataTable.Schema.t`** gains `child_key_fields`. Schema
   constructors that declare `children_key` without it now fail at
   build time.
2. **`Rho.Stdlib.DataTable.Table` internals** lose `apply_child_change`
   and gain a unified `apply_change` that dispatches on `child_key`.
   Public API (`update_cells/2`) signature unchanged but the change-map
   shape changes (`child_key` field replaces magic strings).
3. **`Rho.Stdlib.Plugins.DataTable.update_cells_tool`** parameter
   schema and description change. Existing tape-replays that captured
   the old form become unreplayable. Acceptable.
4. **`Rho.Stdlib.Plugins.DataTable.edit_row_tool`** gains
   `child_match_field` / `child_match_value` / `child_match_json` /
   `child_set_*`. Backwards-compatible for parent-only edits.
5. **`maybe_elide_complex_columns`** stops eliding the
   `children_key` column. Any test asserting `<list<N>>` for
   `proficiency_levels` updates.
6. **`render_table_index`** gains a child-columns line and a stable
   "this table has children" hint. (Cosmetic.)
7. **`RhoFrameworks.DataTableSchemas.library_schema/0`** declares
   `child_key_fields: [:level]`. (One-line addition.)
8. **Agent system prompt** in `.rho.exs` rewritten to describe the new
   locator shape. Drops every reference to `child:<idx>:`.
9. **Existing tests** in
   `apps/rho_stdlib/test/rho/stdlib/data_table_test.exs` and
   `apps/rho_stdlib/test/rho/stdlib/plugins/data_table_test.exs` —
   any that constructed change maps with magic-string fields need
   rewriting to the new shape. The semantic test bodies don't change;
   only the change-map literal.

What does NOT break:

- Persistence (`{:array, :map}` embedded — untouched).
- LiveView rendering (still gets nested rows from the GenServer).
- `add_rows` / `delete_rows` / `replace_all` (parent-row ops are
  unchanged; whole-skill writes carry their levels as before).
- Cross-table consistency (no FKs introduced).

## Test plan

End-to-end through the public tool surface, not through internal
helpers.

1. **Edit a child cell by natural key.**
   `edit_row(table: "library", match: skill_name=Python,
   child_match: level=3, set: level_description=...)` → child row
   updated, no other levels touched, parent row's other fields
   unchanged.
2. **Reorder safety.** Insert a skill with levels in order
   [3, 1, 2, 4, 5]. Edit `level=3` description. Verify the right
   level was edited regardless of array position.
3. **Add a level via add_rows.** New tool surface or extended
   `update_cells` — TBD during implementation. Out of scope for the
   first cut if `replace_all` is still the pattern.
4. **Validation.**
    - `set_field: "level_descrption"` (typo) → `{:error,
      {:unknown_child_field, "level_descrption", available: [...]}}`.
    - `child_match: level=99` → `{:error, {:no_match, ...}}`.
    - Two children with `level=3` (shouldn't be possible if we add a
      uniqueness check on child_key_fields, but worth a test) →
      `{:error, {:ambiguous_match, ...}}`.
    - `child_match` provided but parent's schema has no
      `children_key` → `{:error, {:no_children, table_name}}`.
5. **Query visibility.** `query_table(table: "library", filter:
   skill_name=Python)` returns the row with `proficiency_levels` as a
   list of maps (not `<list<N>>`). Agent can read level numbers and
   pick which to edit without a second query.
6. **Prompt section.** `render_table_index` includes a `child columns
   (proficiency_levels[]): level, level_name, level_description`
   line for the library table; nothing for `role_profile`.

## Suggested ordering

1. **Schema + Table internals.** Add `child_key_fields`. Rewrite
   `apply_change` to dispatch on `child_key`. Delete the positional
   path. Update internal table tests.
2. **Plugin tool surface.** Extend `edit_row` and `update_cells` for
   the new shape. Update plugin tests.
3. **Stop eliding children in `query_table`.** One-line carve-out.
4. **Prompt section + agent system prompt.**
5. **Sweep callsites.** `RhoFrameworks.DataTableSchemas`,
   `mix rho.import_framework`, `library.ex`, anywhere else that
   builds change maps. Most touch the `add_rows`/parent path and
   need no changes; the few that issued cell updates against children
   move to the new shape.

Each step compiles and tests independently. Step 1 is the largest;
2 onward are incremental.

## The case I considered and rejected

If at some future point we *do* need cross-skill queries on level data
("which skills have a level-3 description containing X?"), or
independent identity for proficiency levels (e.g. they get pinned,
versioned, commented on, etc.), Option B becomes the right call and
this design is what stands in the way. Two ways out:

- Promote children to their own table at that point. Migration is
  mechanical because they already have stable ids.
- Or build Option C (virtual flattened view) on top of this — also
  cheaper because children are already first-class rows.

Either way, this design doesn't paint us into a corner; it just
declines to solve a problem we don't yet have.

---

## Adjacent issue: `generate_proficiency` has no selectivity

While we're touching proficiency editing, the partner tool that
*creates* proficiency data has the inverse problem: it can only
operate on every skill in a library at once, and it overwrites
silently. Worth fixing in the same arc since both touch the same
data and the same user mental model ("just these skills").

### Evidence

- `apps/rho_frameworks/lib/rho_frameworks/tools/workflow_tools.ex:195`
  — the tool definition only accepts `table_name` and `levels`.
- `apps/rho_frameworks/lib/rho_frameworks/use_cases/generate_proficiency.ex:91`
  — `start_fanout` calls `DataTable.get_rows(... table: table_name)`,
  groups by `:category`, and fans out one Task per category covering
  every skill in that category.
- `apps/rho_frameworks/lib/rho_frameworks/data_table_ops/set_proficiency_level.ex:29`
  — persistence is a blind `update_cells` overwrite of the
  `proficiency_levels` field. No diff, no merge, no "only fill empty
  slots".

### Three problems, in order of severity

1. **Destructive overwrite of user edits.** `persist_skill`
   (`generate_proficiency.ex:196`) skips a skill only when
   `skill_name` is blank or `levels` is empty — never because the
   row already had levels. After Phase 1+2 of this redesign, when
   the agent can finally edit a `level_description` cleanly, the
   next `generate_proficiency` call will silently throw that work
   away. This is a regression risk we should fix in the same arc.

2. **No way to scope the run.** Three real user intents have no
   path:
    - "Just the skills I selected." The DataTable server already
      tracks `selections` per table (`server.ex` +
      `ActiveViewListener`), and the agent's prompt section already
      shows them. The tool just doesn't accept a selection arg.
    - "Just the skills missing levels." Should arguably be the
      default. Filter is one clause after `get_rows`.
    - "Just this category." `by_category` already groups internally
      — exposing a filter is one line.

3. **Unbounded fan-out.** One Task per category, no concurrency cap.
   A 50-category library fires 50 simultaneous BAML streams. Lower
   priority than 1 and 2 but worth noting.

### Proposal

Extend the `generate_proficiency` tool with three optional params:

```elixir
tool :generate_proficiency, "..." do
  param(:table_name, :string, required: true)
  param(:levels, :integer)
  param(:only_missing, :boolean,
        doc: "Skip skills that already have proficiency_levels (default: true)")
  param(:skill_names, {:list, :string},
        doc: "Restrict to these skill names (full match)")
  param(:categories, {:list, :string},
        doc: "Restrict to these categories")
  param(:use_selection, :boolean,
        doc: "Restrict to the user's selected rows in this table")
  ...
end
```

Plumb through to `start_fanout` as a single `filter_rows/2` step
applied to the result of `DataTable.get_rows/2` before the
`Enum.group_by` line. Filters compose (AND): selection narrows
first, then category, then skill_names, then `only_missing`.

`only_missing` should default to **true**. The existing call sites
that genuinely want full regeneration (the `CreateFramework` flow
runner — see `RhoFrameworks.FlowRunner`) pass `only_missing: false`
explicitly, which doubles as documentation that they intend to
overwrite.

### Out of scope (deliberately)

- Concurrency cap. Worth doing once we observe a real cost issue
  in production; not now.
- Per-skill cancellation. The current Task-per-category granularity
  is fine.
- Diff-merge ("regenerate only level 3 of Python"). The redesigned
  `edit_row` covers this case directly — the agent doesn't need
  `generate_proficiency` for single-cell edits.

### Migration

`only_missing: true` as the default changes existing behavior. Two
ways to handle it:

- a. Ship with default `false`, document that callers should opt in.
     Loses the safety win for the chat-side tool.
- b. Ship with default `true`, update `RhoFrameworks.FlowRunner`'s
     CreateFramework flow to pass `only_missing: false` since the
     wizard's intent is "fill the empty skeleton".

Pick (b). The wizard is the only call site that actually wants the
old behavior, and making it explicit is good. (And `RhoFrameworks.UseCases.GenerateProficiency.run/2` still
accepts the raw `input` map — the FlowRunner change is a one-line
key addition.)

### Test plan

In `apps/rho_frameworks/test/rho_frameworks/use_cases/generate_proficiency_test.exs`:

1. `only_missing: true` (default) skips rows whose
   `proficiency_levels` is non-empty. Assert via the seam-input
   `skills:` payload — only rows missing levels appear.
2. `only_missing: false` includes everything (current behavior).
3. `skill_names: ["Python", "Elixir"]` restricts the seam input to
   those two regardless of category grouping.
4. `categories: ["Tech"]` restricts to that category. Composes with
   `skill_names`.
5. `use_selection: true` restricts to ids returned by
   `DataTable.get_selection/2`. With no selection set →
   `{:error, :empty_selection}` (loud failure, not silent zero-run).
6. All filters compose to empty → `{:error, :empty_rows}` (existing
   error shape, just reached via filter rather than empty table).

### Suggested ordering vs the main redesign

Land the proficiency-editing redesign (Phases 1–5 above) first.
Then add `only_missing: true` as a single follow-up commit — small,
self-contained, and it's the regression guard for the new editing
capability. The other two filters (`skill_names`, `categories`,
`use_selection`) can ship together or separately — they're pure
ergonomics on top.

---

## Prompt surfaces — what the agent needs to be told

New capability the agent can't see is wasted work. Both arcs above
add capabilities that require prompt updates to actually get used.
This section consolidates every surface that needs to change.

### 1. Tool descriptions (auto-flow into the LLM's tool schema)

These are the highest-leverage updates — every turn the tool is
visible, this text is in context.

- **`update_cells`** (`apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex:399`).
  Description: drop "Update data table cells." Replace with one
  paragraph explaining the change-map shape, including the child
  form. Example shape in the description, not just `changes_json`'s
  `doc:`:
  ```
  "Update cells. Change-map fields: {id, field, value} for top-level
  columns, or {id, child_key, field, value} where child_key is a
  map of child_key_fields → values (e.g. {\"level\": 3}) for nested
  children declared via children_key. Validates field names against
  the schema; unknown fields error."
  ```

- **`edit_row`** (`apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex:432`).
  Description: extend the existing locator language explanation to
  include `child_match_*`. New params get `doc:` strings:
  - `child_match_field` — `"Child key field, e.g. \"level\". Required
    when editing a nested child."`
  - `child_match_value` — `"Child key value, e.g. \"3\"."`
  - `child_match_json` — `"Multi-field child locator as JSON object."`

- **`generate_proficiency`** (`apps/rho_frameworks/lib/rho_frameworks/tools/workflow_tools.ex:195`).
  Description rewrite:
  ```
  "Generate proficiency levels for skeleton skills. By default, only
  fills skills that don't already have levels — won't overwrite
  existing data. Pass only_missing: false to regenerate. Scope with
  skill_names, categories, or use_selection (the user's checked
  rows). Fans out one writer per category; blocks until all finish."
  ```
  Each new param's `doc:` mirrors the proposal in the previous
  section.

### 2. `.rho.exs` — `:spreadsheet` agent's `system_prompt` (lines 35–74)

Two edits to the existing "Editing tables" block:

- **Replace the bullet about `update_cells`'s row-patch warning with
  the new shape.** The warning ("do not use a row-patch shape") was
  there because `field`/`value` is the only top-level edit form;
  with `child_key` added we still want that rule, but we also want
  to teach the child form. Proposed text:
  ```
  - One row, one field: `edit_row` with flat string params. For a
    nested level (e.g. proficiency_levels), add child_match_field +
    child_match_value (e.g. child_match_field="level",
    child_match_value="3").
  - Multiple rows or multiple fields: `update_cells`. Each entry is
    {id, field, value} for top-level cells, or {id, child_key:
    {<key>: <value>}, field, value} for a nested child. Never use a
    row-patch shape ({id, skill_name: ...}); every entry must have
    explicit field + value.
  ```

- **Add a short "Regenerating proficiency" paragraph** so the agent
  knows the default skips already-filled rows:
  ```
  Regenerating proficiency:
    - generate_proficiency by default fills only skills missing
      levels — safe to call after edits without losing them.
    - To redo a single level for one skill, use edit_row, not
      generate_proficiency.
    - To force a full regeneration (e.g. user wants fresh
      Dreyfus-style descriptions across the board), pass
      only_missing: false explicitly.
    - To target a subset, pass skill_names, categories, or
      use_selection: true.
  ```

The other agents in `.rho.exs` (`:data_extractor`, `:hiring`, etc.)
don't touch `update_cells` / `edit_row` / `generate_proficiency`, so
they don't need changes.

### 3. `.agents/skills/create-framework/SKILL.md`

This skill is loaded eagerly when the chat agent starts a
framework-creation flow, so it's effectively part of the system
prompt for that path. Two edits:

- **Step 5** currently reads:
  > Generate levels — ONLY after explicit user approval, call
  > `generate_proficiency` with `table_name: "library:<framework
  > name>"` and `levels:` (default 5). …

  Add: "By default this only fills skills missing levels. For the
  initial post-skeleton generation, pass `only_missing: false` —
  the skeleton has no levels yet, but being explicit avoids
  ambiguity if the user re-runs."

- **New anti-pattern** under the existing list:
  > ❌ Calling `generate_proficiency` to fix a single level
  > description — that's a `generate_proficiency` for the entire
  > library and overwrites everything not flagged in the filter.
  > Use `edit_row` with `child_match_field: "level"` instead.

### 4. `.agents/skills/import-framework/SKILL.md`

Only one passing reference to "proficiency levels" (line 25). No
update needed — it's about parsing the source document, not
about generating or editing levels.

### 5. DataTable plugin `prompt_section`

Already covered in Phase 1.2 of the main redesign: `render_table_index`
gains a `child columns (proficiency_levels[]): level, level_name,
level_description` line for schemas with `children_key` set. This is
what tells the agent the child columns *exist* — without it, the
new tool params look like dead weight.

### Coordination

Phase 1.2 and Phase 1.3 of the main redesign already cover updates
1.A (DataTable tool descriptions for `update_cells`/`edit_row`),
2 (the `:spreadsheet` system prompt's editing block), and 5 (the
prompt section). What this section adds:

- Update 1.B: the `generate_proficiency` tool description — ships
  with the `only_missing` default change.
- Update 2's "Regenerating proficiency" paragraph — ships in the
  same commit as `only_missing: true` so the agent learns the new
  default and the new defaults arrive together.
- Update 3: `create-framework/SKILL.md` — same commit as the
  generate_proficiency change.

So the prompt updates split cleanly along the same arc seam: the
editing-redesign commit carries the editing-related prompt
changes; the `generate_proficiency` commit carries its own.
