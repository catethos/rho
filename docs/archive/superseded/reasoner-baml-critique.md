# Structured Reasoner — BAML Refactor Critique

Review of `reasoner-baml-plan.md`. Focuses on architectural risks, NIF pitfalls,
migration blast radius, and alternative phasing.

> **Vocabulary note (post-refactor).** "Reasoner" here = `Rho.TurnStrategy`
> in current code. See `CLAUDE.md` §"Migration from Mount/Memory/Reasoner"
> for the alias table.

---

## 1. Don't make BAML IR the canonical schema too early

The plan proposes replacing `parameter_schema` keyword lists with
`%Rho.Parse.Class{}` across every tool module. This makes a vendored parser's
internal representation part of Rho's public internal contract before the parser
is even proven in production.

**Recommendation:** keep `Rho.Parse` as the only public entrypoint. Tool modules
should not feel like they're talking directly to vendored Rust-era IR structs.
Treat BAML IR as an implementation detail; expose a Rho-owned schema contract on
top. Only unify after `:baml` is validated in production.

---

## 2. The flat optional-field union (Path A) is the weakest part

The proposed `AgentAction` flat class puts every tool's fields as optional
siblings. Problems:

- **Field collisions.** `path`, `message`, `target`, `content` appear in many
  tools with different types or semantics. The plan's coalesce-or-error policy
  will generate noise immediately.
- **Prompt clarity.** The model sees a wall of optional fields with no grouping.
  It will fill unrelated fields (e.g. set `code` on a `bash` action).
- **Validation is mushy.** "action says X but unrelated optional fields are
  present" is hard to handle cleanly.

**Alternative — nested-per-tool objects:**

```json
{
  "thinking": "...",
  "action": "add_rows",
  "add_rows": { "rows": [...] }
}
```

Each tool gets one optional nested key. No field collisions, no dead fields in
the schema, no waiting for tagged enums. Still avoids double-escaping.

---

## 3. Harden the NIF boundary (Phase 0 gaps)

The plan's Phase 0 focuses on vendoring and building but underspecifies
operational hardening:

- **Scheduler starvation.** `parse_response/3` and `parse_partial/3` are CPU
  work. Mark all non-trivial NIF functions as `DirtyCpu` via Rustler's
  `schedule` attribute.
- **Graceful degradation.** Add `Rho.Parse.nif_available?/0`. If the NIF fails
  to load (unsupported platform, bad precompile), the app must still boot.
  `:baml` reasoner should be disabled, not crash the supervisor.
- **O(n²) streaming cost.** Reparsing the full accumulated text on every token
  batch gets expensive for large outputs. Throttle `parse_partial` by
  time/bytes (e.g. every 200ms or 512 bytes), not every delta. Stop partial
  parsing once action is stable enough for UI.
- **IR marshalling overhead.** Passing the full union IR struct into the NIF on
  every partial parse can become the bottleneck. Build the union IR once per
  turn and reuse it; consider compiled-schema/resource-handle caching later.
- **Fuzz safety.** Lenient parser + arbitrary LLM output is exactly where fuzz
  bugs appear. Add property-based tests with StreamData. Treat NIF parse
  failure as recoverable, never process-killing.
- **Telemetry.** Add `:telemetry.execute` for parse time, input bytes, and
  failure counts from day one.
- **Upstream tracking.** Record the source commit hash and local diffs in an
  `UPSTREAM.md` or similar so future updates are tractable.
- **Regression corpus.** Collect real malformed model outputs from production
  logs and add them as test fixtures, not just hand-written unit cases.

---

## 4. Migration blast radius is larger than the plan states

The plan lists ~17 tool files for Phase 2 migration. A grep for
`parameter_schema` reveals more:

- `framework_persistence`, `py_agent`, `live_render`, `doc_ingest`,
  `search_history`, `end_turn`, demos, and other mounts also use the keyword
  list format.
- `Rho.Mount.tool_def` assumes `%{tool: ReqLLM.Tool.t(), execute: fn}`.
- `Runtime.req_tools`, `tool_map`, and downstream code depend on that shape.
- CLI/EventLog/worker code consume `:structured_partial` with a specific
  `%{"action" => ..., "action_input" => ...}` payload shape.

Migrating all tools in Phase 2 while also proving a new reasoner is too much
simultaneous change.

**Recommendation:** migrate only the JSON-string-heavy tools first
(`add_rows`, `add_proficiency_levels`, `update_cells`, `replace_all`). These are
the actual pain points. Leave everything else on keyword lists until BAML is
proven.

---

## 5. Consider proving the value without the NIF first

The double-escaping problem can be tested with a simpler change: modify the
structured envelope to:

```json
{"thinking": "...", "action": "add_rows", "input": {"rows": [...]}}
```

Validate `input` in Elixir against an adapted schema. This eliminates
double-escaping immediately and lets you measure the UX/accuracy win before
committing to a Rust NIF and a new canonical schema system.

If the experiment works, the BAML NIF becomes a **performance/robustness
upgrade** rather than a coupled architectural bet.

---

## 6. Add a reasoner hook instead of another special-case branch

`AgentLoop.build_runtime/3` already special-cases `Rho.Reasoner.Structured` for
prompt injection. Adding another `if reasoner == Rho.Reasoner.BAML` branch will
not scale.

**Recommendation:** add a behaviour callback:

```elixir
@callback prompt_sections(tool_defs :: [tool_def()]) :: [Rho.Mount.PromptSection.t()]
```

Each reasoner returns its own prompt material. `AgentLoop` calls it generically
instead of pattern-matching on modules.

---

## 7. Existing BEAM pitfall already present

`AGENTS.md` documents that `function_exported?/3` requires `Code.ensure_loaded!/1`
first. `MountRegistry.safe_call/4` uses `function_exported?/3` without loading
the module. Fix this before adding more module-driven schema behaviour — it's the
kind of silent failure that will waste hours during migration.

---

## 8. Event payload size

Large typed arrays in `tool_start` / `structured_partial` can flood logs and UI.
`EventLog` already truncates, but the truncation boundary matters more when args
go from `"[{...}]"` (one string) to `[%{...}, %{...}, ...]` (1000 maps).

**Recommendation:** emit summarized previews for large collections
(`rows: "1000 items"`) in high-frequency events. Keep full payloads only in
low-frequency events (`tool_result`).

---

## Revised phasing

| Phase | Scope | Risk |
|---|---|---|
| **0** | Vendor + harden NIF boundary (DirtyCpu, fallback, telemetry, fuzz) | Low |
| **1** | `:baml` reasoner via adapter, nested-per-tool union, no tool rewrites | Medium |
| **1.5** | Migrate only JSON-string-heavy tools (add_rows, etc.) | Low |
| **2** | Broader schema unification — only if Phase 1 metrics justify it | Medium |
| **3** | Tagged enums — only if flat/nested shape causes measured problems | Low |

This gets the main benefit (no double-escaping, lenient parsing) quickly while
avoiding the two biggest risks: **BEAM/NIF fragility** and **prematurely making
vendored IR the framework-wide contract**.
