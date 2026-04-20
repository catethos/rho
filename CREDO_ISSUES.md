# Credo Refactoring Issues

21 remaining issues (down from 80 originally, 42 at start of session).

## apps/rho/ (Core Runtime)

### `lib/rho/action_schema.ex`
- [ ] **L155** — Cyclomatic complexity 13 (max 9) — `dispatch/3`

### `lib/rho/agent/lite_worker.ex`
- [ ] **L396** — Cyclomatic complexity 13 (max 9)

---

## apps/rho_frameworks/ (Skill Assessment Domain)

### `lib/mix/tasks/rho.import_framework.ex`
- [ ] **L71** — Cyclomatic complexity 25 (max 9)
- [ ] **L238** — Nesting depth 6 (max 2)
- [ ] **L395** — Nesting depth 3 (max 2)

---

## apps/rho_web/ (Phoenix Web)

### `lib/rho_web/components/data_table_component.ex`
- [ ] **L312** — Nesting depth 3 (max 2)
- [ ] **L1102** — Nesting depth 3 (max 2)
- [ ] **L1210** — Cyclomatic complexity 13 (max 9) — `build_csv`
- [ ] **L1246** — Nesting depth 5 (max 2)
- [ ] **L1264** — Cyclomatic complexity 24 (max 9)
- [ ] **L1307** — Nesting depth 5 (max 2)

### `lib/rho_web/components/lens_chart_components.ex`
- [ ] **L41** — Cyclomatic complexity 23 (max 9)
- [ ] **L132** — Cyclomatic complexity 19 (max 9)
- [ ] **L222** — Cyclomatic complexity 12 (max 9)

### `lib/rho_web/live/app_live.ex`
- [ ] **L2195** — Cyclomatic complexity 12 (max 9) — `handle_info` (signal dispatch)
- [ ] **L2952** — Nesting depth 3 (max 2) — `apply_open_workspace_event`

### `lib/rho_web/live/flow_live.ex`
- [ ] **L476** — Cyclomatic complexity 19 (max 9)
- [ ] **L585** — Cyclomatic complexity 11 (max 9) — `handle_worker_completed`

### `lib/rho_web/live/session_live.ex`
- [ ] **L838** — Cyclomatic complexity 10 (max 9) — `handle_info`

### `lib/rho_web/live/session_live/data_table_helpers.ex`
- [ ] **L339** — Cyclomatic complexity 10 (max 9)

### `lib/rho_web/projections/session_state.ex`
- [ ] **L599** — Cyclomatic complexity 10 (max 9)

---

## Summary by type

| Issue | Count |
|-------|-------|
| Cyclomatic complexity | 14 |
| Nesting depth | 7 |
| **Total** | **21** |

## Hotspots (most issues per file)

| File | Issues |
|------|--------|
| `data_table_component.ex` | 6 |
| `lens_chart_components.ex` | 3 |
| `import_framework.ex` | 3 |
| `app_live.ex` | 2 |
| `flow_live.ex` | 2 |
