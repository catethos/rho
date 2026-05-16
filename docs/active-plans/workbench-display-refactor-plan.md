# Workbench Display Refactor Plan

## Why This Exists

Recent Workbench welcome-page changes exposed a recurring problem: simple user actions require too many coordinated state updates across LiveView, the data-table server, projections, workbench context, and component rendering.

Examples:

- Opening a saved library loaded table data but could still leave the Workbench home overlay visible.
- Long library tab labels changed the editor header height because tab rendering had no stable display contract.
- Closing opened libraries required wiring through tab markup, component events, AppLive messages, data-table server mutation, projection refresh, and fallback tab selection.
- Library creation actions, library browser state, assistant state, and editor tabs are conceptually related but rendered and controlled in separate places.

The current system works, but it is error-prone because display state is implicit and distributed.

## Current Pain Points

Display behavior is split across:

- `Rho.Stdlib.DataTable.Server` for table existence, rows, order, selections, and active table.
- `RhoWeb.Projections.DataTableProjection` for cached UI snapshots.
- `Rho.Stdlib.DataTable.WorkbenchContext` for artifact/workflow meaning.
- `RhoWeb.AppLive` for workspace visibility and `workbench_home_open?`.
- `RhoWeb.AppLive.DataTableEvents` for event handling, refreshes, loading, tab switching, and close behavior.
- `RhoWeb.DataTableComponent` for home/editor selection, tabs, artifact header, row table, dialogs, and local events.
- `RhoWeb.WorkbenchActionComponent` for the Workbench home library browser and modals.

This creates two main risks:

1. A user action can update data correctly but fail to update display state.
2. Component layout can change based on content because there is no explicit display contract for tabs, home mode, and editor mode.

## Target Model

Introduce one explicit display state for the Workbench surface.

```elixir
%RhoWeb.WorkbenchDisplay{
  mode: :home | {:table, String.t()},
  active_table: String.t() | nil,
  open_tables: [String.t()],
  loading_tables: MapSet.t(String.t()),
  error: term() | nil
}
```

The exact fields can evolve, but the key principle is that `mode` becomes the source of truth for what the user sees.

Desired behavior:

- Opening a library always sets `mode: {:table, table_name}`.
- Closing an active tab selects the next sensible table.
- Closing the last non-main table returns to `mode: :home`.
- Showing the Workbench home is a mode change, not an overlay exception.
- The data-table server owns table data; `WorkbenchDisplay` owns what is visible.

## Proposed Commands

Create a small module, likely `RhoWeb.WorkbenchDisplay`, with reducer-style functions:

```elixir
open_library(socket, library_id)
switch_table(socket, table_name)
close_table(socket, table_name)
show_home(socket)
hide_home(socket)
refresh_from_tables(socket)
```

Each command should update all required display state in one place:

- `active_table`
- `mode`
- `workbench_home_open?` replacement or compatibility field
- projection state
- table snapshots
- fallback selection
- workspace visibility when needed

## Refactor Steps

### 1. Extract Tab Rendering

Create a focused `RhoWeb.DataTableTabsComponent` or function component that owns:

- tab strip markup
- close buttons
- stable tab dimensions
- ellipsis behavior
- tab events: select and close

Keep it pure-rendering where possible. Parent components can still receive `{:data_table_switch_tab, name}` and `{:data_table_close_tab, name}` initially.

### 2. Introduce `WorkbenchDisplay`

Add a module responsible for display decisions:

- home vs editor
- active table fallback
- whether a table is closable
- display order rules
- loading state

Start with pure helpers, then move state mutation into command functions.

### 3. Route Existing Events Through Commands

Move these paths behind `WorkbenchDisplay` or a similarly named display coordinator:

- `workbench_library_open`
- `data_table_switch_tab`
- `data_table_close_tab`
- `workbench_home_open`
- `hide_workbench_home`
- `open_workbench_home`

Do this incrementally. Keep existing message names until callers are migrated.

### 4. Replace `workbench_home_open?`

Deprecate `workbench_home_open?` as a primary display flag.

Short-term compatibility:

```elixir
home? = WorkbenchDisplay.home?(display, data_state)
```

Long-term:

```elixir
case display.mode do
  :home -> render_home(...)
  {:table, table_name} -> render_editor(...)
end
```

### 5. Separate Data Refresh From Display Decisions

Keep `Rho.Stdlib.DataTable.Server` as the source of truth for rows/tables.

But avoid making display decisions inside refresh code. Refresh should answer:

- what tables exist?
- what is the active snapshot?
- did a table load finish?

Display commands should answer:

- what should the user see now?
- what tab should become active after close?
- when should the home browser appear?

### 6. Reduce `DataTableComponent`

After tabs and display decisions move out, split or simplify `DataTableComponent` by ownership:

- `WorkbenchHomeComponent`
- `DataTableTabsComponent`
- `DataTableArtifactHeaderComponent`
- `DataTableGridComponent`
- `DataTableDialogsComponent`

This should address the recurring `rho.arch` warning that `DataTableComponent` is too large.

## Acceptance Criteria

- Opening a library always shows the skill editor for that library.
- Closing the active library tab never leaves the UI in a blank or stale state.
- Closing the last open library returns to the library browser.
- Workbench home rendering depends on one explicit display mode.
- Tab strip height is stable regardless of library name length.
- Data refreshes do not independently decide home/editor visibility.
- New tests cover display transitions:
  - home -> open library -> editor
  - editor -> show home -> home
  - active tab close -> fallback editor
  - last tab close -> home
  - async library load completion keeps current display mode stable

## Suggested First Patch

Start small:

1. Add `RhoWeb.WorkbenchDisplay` with pure helpers:
   - `home?/2`
   - `closable_table?/1`
   - `fallback_table/1`
   - `mode_after_close/2`
2. Move fallback tab selection from `DataTableEvents` into this module.
3. Add tests for the pure helpers.
4. Only then route `data_table_close_tab` and `workbench_library_open` through it.

This gives us value quickly without a risky rewrite.
