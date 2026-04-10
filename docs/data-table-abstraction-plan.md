# DataTable Abstraction Plan

## Goal

Rename "spreadsheet" to "data table" and make the component generic — driven by a column schema instead of hardcoded skill fields. This unblocks the skill library restructure (two table modes with different columns) and makes the component reusable for any tabular data.

## Rename Map

| Old | New |
|-----|-----|
| `SpreadsheetProjection` | `DataTableProjection` |
| `SpreadsheetComponent` | `DataTableComponent` |
| `Rho.Stdlib.Plugins.Spreadsheet` | `Rho.Stdlib.Plugins.DataTable` |
| `:spreadsheet` (plugin shorthand) | `:data_table` |
| `rho_spreadsheet_registry` (ETS) | `rho_data_table_registry` |
| `spreadsheet_*` signal topics | `data_table_*` signal topics |
| `spreadsheet_get_table` message | `data_table_get_table` message |
| `@ws_states[:spreadsheet]` | `@ws_states[:data_table]` |
| `spreadsheet-*` CSS classes | `dt-*` CSS classes |

## Step 1: Define Column Schema

Create `RhoWeb.DataTable.Schema` — a struct describing a table's shape:

```elixir
defmodule RhoWeb.DataTable.Schema do
  defstruct [
    :title,
    :empty_message,
    columns: [],
    group_by: [],
    known_fields: []  # derived from columns
  ]

  defmodule Column do
    defstruct [:key, :label, :type, :editable, :css_class]
    # type: :text | :number | :textarea
    # editable: boolean, default true
  end

  def known_field_names(%__MODULE__{columns: cols}) do
    Enum.map(cols, & Atom.to_string(&1.key))
  end
end
```

Predefined schemas live in domain modules (e.g., `RhoFrameworks` defines skill library and role profile schemas).

## Step 2: Refactor DataTableProjection

- Rename file: `spreadsheet_projection.ex` → `data_table_projection.ex`
- Rename module: `SpreadsheetProjection` → `DataTableProjection`
- Replace `@known_fields` compile-time constant with a dynamic field stored in state
- `init/0` → `init/1` accepting a schema (or `init/0` with a default that includes all current fields for backwards compat)
- Signal suffixes: `spreadsheet_*` → `data_table_*`
- All reducer logic stays identical — it's already generic

## Step 3: Refactor DataTableComponent

- Rename file: `spreadsheet_component.ex` → `data_table_component.ex`
- Rename module: `SpreadsheetComponent` → `DataTableComponent`
- Accept `columns` and `group_by` as assigns (from schema)
- Replace hardcoded `<th>` and `<.editable_cell>` with loops over `@columns`
- Replace hardcoded `category`/`cluster` grouping with dynamic `@group_by`
- Title and empty message come from assigns
- CSS class prefix: `ss-` → `dt-`

## Step 4: Refactor DataTable Plugin

- Rename file: `spreadsheet.ex` → `data_table.ex`
- Rename module: `Rho.Stdlib.Plugins.Spreadsheet` → `Rho.Stdlib.Plugins.DataTable`
- Replace hardcoded `normalize_row/1` with schema-driven normalization
- Remove `build_summary/1` hardcoded grouping — make it schema-driven
- Remove `add_proficiency_levels` tool (domain-specific → moves to `RhoFrameworks.Plugin`)
- Remove skill-specific `prompt_sections` (domain-specific → moves to `RhoFrameworks.Plugin`)
- ETS table: `:rho_spreadsheet_registry` → `:rho_data_table_registry`
- Signal topics: `spreadsheet_*` → `data_table_*`

## Step 5: Move Domain-Specific Code to RhoFrameworks.Plugin

- `add_proficiency_levels` tool
- Skill-specific `prompt_sections`
- Skill library and role profile column schema definitions

## Step 6: Update Session LiveView + Wiring

- `@workspace_registry` key: `:spreadsheet` → `:data_table`
- `handle_info` message: `:spreadsheet_get_table` → `:data_table_get_table`
- Component references in templates
- CSS class references in inline CSS

## Step 7: Update Plugin Shorthand Map

- `Rho.Stdlib` module map: `:spreadsheet` → `:data_table`
- Keep `:spreadsheet` as a deprecated alias pointing to same module

## Implementation Order

1 → 2 → 3 → 4 → 5 → 6 → 7 (sequential — each step builds on the previous)
