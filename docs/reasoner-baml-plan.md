# Structured Reasoner — Tagged-Union Refactor Plan (v3, no NIF)

## ⚠ Superseded 2026-04-05 — :tagged reasoner removed

Phase 1 live eval exposed two regressions on `:tagged`
(see `docs/reasoner-baml-results.md`): it skipped the
spreadsheet agent's mandatory skeleton phase + user-approval
gate, and reported +17% output tokens. `:tagged` was removed
and `Rho.Parse.Lenient` was redirected to streaming UX — see
`docs/tagged-removal-and-lenient-streaming-plan.md`.

This plan remains as a historical record of the design
intent and corpus-building work.

---

## Status — 2026-04-05 (late)

**Phase 1 validation harness + corpus + properties: shipped.** Suite green:
387 tests + 10 properties, 0 failures.

What landed (this session):
- `Rho.Test.ReasonerHarness` (`test/support/reasoner_harness.ex`) — replays
  a fixture LLM response through a named reasoner with a fake tool_map,
  returns `%{dispatched, heuristic_hits, reprompts, tokens, events, result}`.
  Structural heuristic detection (`structured_heuristics/2`) classifies
  which `:structured`-reasoner recovery paths would fire per fixture.
- `test/rho/reasoner/comparison_test.exs` — 15 adversarial validation-matrix
  cases: bare array, large bare array, multi-line bash, python triple-quoted,
  unicode, fenced JSON, legacy action_input, unknown action, missing/extra
  field, null action, empty, trailing non-JSON. Asserts
  `:tagged.heuristic_hits == 0` across every case.
- `test/fixtures/parse_corpus/` + `MANIFEST.json` — 22 fixtures extracted
  from `_rho/sessions/*/events.jsonl` covering 17 distinct envelope
  signatures (legacy `action_input` wrappers across 11 real tool names,
  plus raw-text final answers).
- `test/rho/reasoner/tagged_corpus_test.exs` — table-driven test per
  fixture: tagged always dispatches correctly (via slip-recovery or
  reprompt) with `heuristic_hits == 0`.
- `test/rho/reasoner/structured_corpus_test.exs` — baseline delta:
  `tagged.hits ≤ structured.hits` invariant across the whole corpus
  (currently `structured=2, tagged=0`).
- `test/rho/parse/lenient_property_test.exs` (StreamData) — 5 properties:
  round-trip, fence invariance, prefix safety on valid-JSON prefixes,
  prefix safety on arbitrary binaries, `parse/1` never raises.
- `test/rho/reasoner/tagged/property_test.exs` (StreamData) — 5 properties:
  variant round-trip, extra-key resilience, missing-field detection,
  slip-recovery invariants, primitive coercion round-trip.
- `test/rho/reasoner/tagged/streaming_test.exs` — 5 throttle-cadence tests:
  short envelope (no partial-parse), long envelope (≥1 partial-parse),
  non-structural tokens (no partial-parse), byte-threshold crossing,
  malformed tokens (never crashes).
- `mix.exs` — added `stream_data ~> 1.1` (test-only) and
  `elixirc_paths: ["lib", "test/support"]` for `:test`.

What landed (prior sessions):
- `Rho.Parse.Lenient` — pure-Elixir parser with fence-strip + auto-close.
- `Rho.Reasoner.Tagged{,.Coerce,.Dispatch,.PromptSection}` — tagged envelope,
  slip recovery, throttled partial-parse, event-payload summarization.
- `prompt_sections/1` reasoner callback (Direct/Structured/Tagged implement
  it; AgentLoop dispatches generically).
- Telemetry: `[:rho, :parse, :lenient, :parse]`,
  `[:rho, :reasoner, :tagged, :slip_recovery]`.
- `:tagged` registered in `Rho.Config.@reasoner_modules`.

Still open in Phase 1 (needs real model traffic):
- End-to-end CLI integration runs and results doc (1.37–1.40).
- Coverage/telemetry verification in production (1.34–1.36).
- Concurrency/load and tape-replay compatibility tests (1.27, 1.28) —
  deferred; not currently blocking.

Landed 2026-04-05 (this session):
- **1.20** — `spreadsheet` agent flipped `:structured` → `:tagged` in
  `.rho.exs`. First real migration. Rationale inline. One agent only —
  waiting on results doc before flipping more.
- **Phase 0** — `MountRegistry.safe_call/4` now `Code.ensure_loaded/1`s
  before `function_exported?/3`. Regression test in
  `test/rho/mount_registry_test.exs` via `Rho.Test.ReloadableMount`
  (purge + collect_tools reloads the module).

## TL;DR

Replace `Rho.Reasoner.Structured` with a tagged-union reasoner built in **pure
Elixir**. No NIF, no Zig, no Rust, no vendored parser.

The envelope is internally tagged:
`{"action": "bash", "thinking": "...", "command": "ls"}`. One discriminator,
variant-specific fields, native JSON types. Parsing uses `Jason` + ~80 LOC of
lenient auto-closing/fence-stripping. Throttled partial-parse handles streaming.

Upgrade path to native/NIF parsing stays open but is **not built until
production metrics demand it**.

---

## First-principles framing

### Problem

`Rho.Reasoner.Structured` uses a flat JSON envelope where tool arguments are
JSON-encoded strings inside another JSON object. Double escaping, token bloat,
and format slippage follow. The reasoner compensates with ad-hoc recovery code
(`detect_implicit_tool`, `lang_to_tool`, `_raw` heuristic, markdown fallback).

### The fix

Separate routing from transport. Model tool dispatch as a **discriminated
union** — each tool is a first-class variant with its own typed fields,
transported as native JSON. Parse leniently (strip fences, auto-close partial
braces); throttle partial-parse to avoid O(n²) streaming work.

### Why no NIF

Rho's payloads are kilobyte-scale. Throttled `Jason.decode/1` (parse every
100ms / 256 bytes / on structural tokens) is O(n · throttle_factor), not
O(n²). At 10KB payloads that's a few milliseconds of parsing total per turn.
Building a streaming parser in Zig/Rust pays build/CI/toolchain tax for a
problem that doesn't yet exist at scale.

The escape hatch — upgrade to a native streaming parser if measurements
warrant — is additive and can be done later without touching the envelope
shape, dispatch logic, or tool contracts.

---

## Envelope shape — internally tagged

```json
{
  "thinking": "I need to add these rows.",
  "action": "add_rows",
  "rows": [{"name": "Alice"}, {"name": "Bob"}]
}
```

```json
{"thinking": "Running a command.", "action": "bash", "command": "ls -la"}
```

```json
{"thinking": "Done.", "action": "final_answer", "answer": "All set."}
```

### Field collisions are resolved by dispatch, not schema

Parsing flow: decode JSON → read `action` → look up tool → validate remaining
fields against *that tool's* `parameter_schema`. `path` in `fs_read` and `path`
in `fs_write` never collide because each is scoped to its variant.

---

## Architectural decisions

### Decision 1 — Pure Elixir, no NIF

Lenient parser is ~80 LOC. `Jason` handles well-formed JSON. Auto-close brace
counting handles streaming partials. Markdown fence stripping is regex.
Telemetry measures when/if this becomes a bottleneck; upgrade only if so.

### Decision 2 — Reasoner hook, not special-case branches

Add `prompt_sections/1` to `Rho.Reasoner` behaviour. Each reasoner supplies
its own prompt material. Kill `AgentLoop` pattern-matching on reasoner module.

### Decision 3 — IR-free design

Tools keep their existing `parameter_schema` keyword lists. The reasoner reads
them directly for per-variant validation. No intermediate IR struct layer, no
cross-language schema type, no DSL (yet).

### Decision 4 — Targeted tool migration only

Only JSON-string-heavy tools (`add_rows`, `add_proficiency_levels`,
`update_cells`, `replace_all`) migrate in Phase 2. The other ~19
`parameter_schema` sites stay untouched until proven necessary.

### Decision 5 — Coexist with existing reasoners

Add `:tagged` alongside `:direct` and `:structured`. Opt-in per agent.
Deprecate `:structured` only after `:tagged` proves stable.

---

## Phase 0 — Pre-refactor cleanup

### 1. Fix `MountRegistry.safe_call` module-load bug

`lib/rho/mount_registry.ex:246` calls `function_exported?/3` without
`Code.ensure_loaded!/1` — silently returns `false` for un-loaded modules in
releases. Fix + regression test.

Independent of this plan but must land first.

---

## Phase 1 — `:tagged` reasoner (pure Elixir)

**Goal:** production reasoner using tagged-union envelopes and Elixir-only
lenient parsing.

### `Rho.Parse.Lenient` (the whole parser)

```elixir
defmodule Rho.Parse.Lenient do
  def parse(text) do
    text |> strip_fences() |> Jason.decode()
  end

  def parse_partial(text) do
    text |> strip_fences() |> auto_close() |> Jason.decode()
  end

  defp strip_fences(text) do
    text
    |> String.replace(~r/\A\s*```(?:json)?\s*\n?/, "")
    |> String.replace(~r/\n?\s*```\s*\z/, "")
    |> String.trim()
  end

  defp auto_close(text) do
    # Scan string; track depth of {, [, and in-string state;
    # append closers at EOF for any unclosed openers.
    ...
  end
end
```

Target: ~80 LOC including auto-close. No NIF.

### Reasoner behaviour change

```elixir
@callback prompt_sections(tool_defs :: [map()]) :: [Rho.Mount.PromptSection.t()]
```

`Direct`, `Structured`, and `Tagged` all implement it. `AgentLoop` dispatches
generically, removing the existing reasoner-module pattern match.

### `Rho.Reasoner.Tagged` flow

```
1. Build prompt_section describing tools as discriminated variants from
   tool_defs (one section, generated once per tool set).
2. Stream via ReqLLM.stream_text.
3. On each token: emit :text_delta, append to accumulator.
4. Throttled partial parse:
     if (structural char in token) AND (100ms elapsed OR 256 bytes since last):
       case Rho.Parse.Lenient.parse_partial(acc):
         {:ok, %{"action" => name} = parsed} -> emit :structured_partial
         _ -> :ok
5. On stream end:
     case Rho.Parse.Lenient.parse(acc):
       {:ok, %{"action" => name} = parsed} ->
         dispatch(name, parsed, tool_map)
       {:error, _} ->
         # one reprompt, then surface error
```

### Dispatch

```elixir
def dispatch("final_answer", %{"answer" => ans}, _), do:
  {:done, %{type: :response, text: ans}}

def dispatch(name, parsed, tool_map) do
  with {:ok, tool_def} <- Map.fetch(tool_map, name),
       {:ok, args} <- extract_and_coerce(parsed, tool_def.parameter_schema) do
    execute_tool(name, args, ...)
  else
    :error -> reprompt("Unknown action: #{name}")
    {:error, reason} -> reprompt("Invalid args for #{name}: #{reason}")
  end
end
```

`extract_and_coerce/2` walks the parsed map, picks fields named in the
schema, coerces primitives ("30" → 30, "true" → true), drops extras, reports
missing required fields.

### Prompt section

Generated from `tool_defs`:

```
OUTPUT FORMAT

Respond with a single JSON object. One `action` field picks the variant;
fill only that variant's fields.

Variants:
- action: "bash" → { command: string }                  // Run a shell command
- action: "python" → { code: string }                   // Run Python code
- action: "add_rows" → { rows: [{name: string, role: string}] }
- action: "final_answer" → { answer: string }           // Respond to user

Always include: { thinking: string, action: string, ...variant_fields }
```

Few-shot examples: one per action-kind, plus a "final_answer" example.

### Partial-parse throttling

Skip `parse_partial` unless:
- Token contains `{}[]":,` AND
- ≥ 100 ms since last call OR ≥ 256 bytes since last call.

Emit `:structured_partial` only when parsed map differs from previous.

Stop partial-parsing once `action` is resolved AND all required fields for
that variant are present in the parsed map.

### Slip recovery

If `parse/1` returns `{:ok, %{"action_input" => inner} = top}` and `top` is
missing expected variant fields, promote `inner` into `top` (legacy envelope
shape). Telemetry counter `[:rho, :reasoner, :tagged, :slip_recovery]`.

If `top` contains required fields but under a legacy `action_input` wrapper,
accept with warning. If `top` has no `action`, reprompt.

### Event payload policy

`:tool_start` and `:tool_result` carry full payloads. `:text_delta` and
`:structured_partial` summarize large collections (e.g. `"rows" => "<473
items>"`). Prevents flooding logs/UI when tools receive thousands of items.

### Files

```
[create] lib/rho/parse/lenient.ex
[create] lib/rho/reasoner/tagged.ex
[create] lib/rho/reasoner/tagged/dispatch.ex
[create] lib/rho/reasoner/tagged/prompt_section.ex
[create] lib/rho/reasoner/tagged/coerce.ex
[create] test/rho/parse/lenient_test.exs
[create] test/rho/reasoner/tagged_test.exs
[create] test/rho/reasoner/tagged/dispatch_test.exs
[create] test/rho/reasoner/tagged/coerce_test.exs
[create] test/fixtures/parse_corpus/          # real assistant messages
[edit]   lib/rho/reasoner.ex                  # add prompt_sections/1 callback
[edit]   lib/rho/reasoner/direct.ex           # implement callback
[edit]   lib/rho/reasoner/structured.ex       # implement callback
[edit]   lib/rho/agent_loop.ex                # generic prompt_sections dispatch
[edit]   lib/rho/config.ex                    # :tagged atom
[edit]   .rho.exs                             # document reasoner: :tagged opt-in
```

### Regression corpus

Collect assistant messages from `_rho/sessions/*/events.jsonl` that triggered
recovery heuristics or parse failures under `:structured`. Each becomes a
deterministic fixture — ensures `:tagged` handles at least the same edge cases.

---

## Validation strategy — proving `:tagged` is better

Proving superiority requires more than happy-path tests. The full validation
matrix:

### 1. Comparison harness (A/B test framework)

`test/rho/reasoner/comparison_test.exs` — replays fixture LLM responses
through both reasoners and asserts `:tagged` wins on every axis.

```elixir
describe "structured vs tagged" do
  test "bare array output — structured needs heuristic, tagged is native" do
    llm_response = ~s([{"name":"Alice"},{"name":"Bob"}])
    structured = run_reasoner(Structured, llm_response, tool_map)
    tagged     = run_reasoner(Tagged,     llm_response, tool_map)

    assert structured.heuristic_hits > 0      # detect_implicit_tool fires
    assert tagged.heuristic_hits == 0
  end

  test "python code with triple-nested quotes — no double-escape on tagged" do
    ...
  end
end
```

Each test emits telemetry-shaped results so the comparison is mechanical, not
eyeballed.

### 2. Adversarial fixtures (cases that broke `:structured`)

`test/fixtures/parse_corpus/` contains real production failures from
`_rho/sessions/*/events.jsonl`. Every fixture is a named case with:

- The raw LLM output.
- Why it was hard (double-escape / fence slip / bare array / unicode).
- Expected dispatch under `:tagged`.
- Heuristic hits under `:structured` (recorded, not required).

Each fixture becomes a test in `tagged_corpus_test.exs` and
`structured_corpus_test.exs` (for baseline delta).

### 3. Specific adversarial cases

Each case gets a named test, with the LLM output hand-crafted to exercise the
pathology:

| Case | Pain under `:structured` | `:tagged` expectation |
|---|---|---|
| Large JSON array (1000 rows) | Doubly-escaped, token bloat, truncation risk | Native array, no escaping |
| Multi-line bash command with quotes | `\\"` escaping explosion | Raw string in `command` field |
| Python code with triple-quoted docstring | Escape soup | Raw string in `code` field |
| Unicode / emoji in args | May survive but fragile | Native UTF-8 |
| Bare JSON array (no envelope) | `detect_implicit_tool` heuristic | Reprompt (no variant match) |
| Markdown-fenced JSON | `parse_fallback` strips fences | Lenient fence-strip built-in |
| LLM emits `action_input` wrapper (legacy) | Happy path | Slip-recovery promotes fields |
| Unknown action name | Reprompt with error | Reprompt with error — same behavior |
| Missing required field | Silent or wrong dispatch | Reprompt with missing-field error |
| Extra field not in schema | Often dropped | Dropped with telemetry counter |
| Action field present but value null | Crash | Reprompt |
| Empty response | Reprompt | Reprompt |
| Response contains only `thinking` | Hang/reprompt | Reprompt |
| Trailing non-JSON content after JSON | Parse failure | Parse succeeds (lenient) |

### 4. Streaming partial-parse tests

`test/rho/reasoner/tagged/streaming_test.exs`:

- Tokens arrive one char at a time → partial-parse fires at expected cadence.
- `action` resolved mid-stream → `:tool_start` event emitted before stream end.
- Required fields complete → partial-parse stops (throttle test).
- Malformed token sequence → never crashes, no process leak.
- Stream ends abruptly mid-object → parse failure handled gracefully.

### 5. Concurrency / load

`test/rho/reasoner/tagged/concurrency_test.exs`:

- 100 parallel `Rho.Parse.Lenient.parse/1` calls → all succeed, no shared
  state corruption.
- 10 agents running `:tagged` concurrently on the same task → all dispatch
  correctly.

### 6. Property-based tests (StreamData)

`test/rho/parse/lenient_property_test.exs`:

- Any valid JSON → roundtrips through lenient parse unchanged.
- Any prefix of valid JSON → `parse_partial` returns `{:ok, map}` or
  `{:error, reason}`, never raises.
- Fenced JSON → lenient parse matches unfenced result.

`test/rho/reasoner/tagged/property_test.exs`:

- Any `{thinking, action, args_per_variant}` → encode → decode → same args.
- Generated variant + random extra top-level keys → dispatch picks right tool,
  ignores extras.

### 7. Token-count comparison (budget regression)

`test/rho/reasoner/tagged/token_count_test.exs` — for N representative
assistant responses:

- Count prompt tokens (schema description).
- Count response tokens (mock LLM output).
- Assert `:tagged` total ≤ `:structured` total per response shape.

Run via `mix test --include slow:true` with `tiktoken_ex` or similar.

### 8. Integration: real agent runs

`test/integration/reasoner_comparison_test.exs` (tagged `:integration`):

- Run one CLI agent task end-to-end under each reasoner.
- Assert:
  - Completion parity (both finish, same result shape).
  - `:tagged` reprompt count ≤ `:structured`.
  - `:tagged` heuristic hits = 0.
- Skip in CI unless `INTEGRATION=1`.

### 9. Tape-replay compatibility

`test/rho/reasoner/tagged/tape_replay_test.exs`:

- Load an existing tape with `:structured`-format assistant messages.
- Run `:tagged` reasoner on top of it (new turns).
- Old turns remain readable as context; new turns use `:tagged` envelope.
- No reformat, no breakage.

### 10. Coverage metric

`mix test --cover` — `Rho.Reasoner.Tagged` and `Rho.Parse.Lenient` at **≥ 95%
line coverage**. Dispatch logic at **100%** (every branch).

### Telemetry

```elixir
:telemetry.execute(
  [:rho, :parse, :lenient, :parse],
  %{duration_us: d, bytes: n},
  %{outcome: :ok | :error, partial?: bool}
)
```

```elixir
:telemetry.execute(
  [:rho, :reasoner, :tagged, :turn],
  %{partial_parse_count: k, parse_us: sum, tokens: n},
  %{outcome: :ok | :reprompt | :error}
)
```

### Exit criteria (Phase 1)

Run representative task (add_rows + bash + final_answer) under `:structured`
vs `:tagged`:

| Metric | Target |
|---|---|
| Double-escaped `\"` in tool args | 0 on `:tagged` |
| `detect_implicit_tool`, `_raw`, `lang_to_tool` hits | 0 on `:tagged` |
| Reprompt rate | `:tagged` ≤ `:structured` |
| Token count per assistant turn | `:tagged` ≤ `:structured` |
| Task completion parity | yes |
| Partial-parse CPU overhead per turn | < 2% |
| Field collision incidents | 0 |

---

## Phase 2 — Migrate JSON-string-heavy tools

**Goal:** fix the worst offenders. Nothing else.

### Audit first

Grep for `_json:` params. Known candidates: `add_rows`,
`add_proficiency_levels`, `update_cells`, `replace_all`. May find others.

### Per-tool migration

1. Update `parameter_schema` from `rows_json: :string` to
   `rows: {:list, :map}` (or nested map schema).
2. Rewrite `execute/1` to accept the decoded list/map directly — drop
   `Jason.decode!`.
3. Verify under `:structured`, `:direct`, `:tagged`.

### Scope discipline

No DSL, no canonical-schema changes, no other tools touched.

### Exit criteria (Phase 2)

- Targeted tools run cleanly on all reasoners.
- Tape replay unaffected (historical turns are context, not reparsed).
- No regression in existing agents.

---

## Phase 3 — Retirement

After `:tagged` proves stable (2–4 weeks of real agent traffic, no material
parse failures, no regression in heuristic-recovery metrics):

1. Mark `Rho.Reasoner.Structured` and `:structured` atom deprecated.
2. Migrate remaining agents to `:tagged` (or `:direct`).
3. Delete:
   - `lib/rho/reasoner/structured.ex`
   - `lib/rho/structured_output.ex`
   - `test/rho/structured_output_test.exs`
   - Heuristic recovery code (`detect_implicit_tool`, `_raw`, `lang_to_tool`).

---

## Future (optional, not committed)

These are **escape hatches**, not planned phases. Build only if production
telemetry demands.

### Native streaming parser

Triggered by: `[:rho, :parse, :lenient, :parse]` p99 > 50ms, or
`partial_parse_count × parse_us` exceeding a meaningful fraction of turn time.

Options when triggered:
- Pure Elixir streaming parser (~400 LOC): maintains tokenizer state across
  chunks, O(n) total. No NIF.
- Zig/Rust NIF streaming parser: only if Elixir streaming insufficient.

### `Rho.Schema` DSL

Tools declare schemas via a Rho-owned DSL that replaces `parameter_schema`
keyword lists. Triggered by: schema definitions becoming unwieldy,
cross-cutting concerns (validation, docs, introspection) repeatedly needed.

Both upgrade paths preserve the envelope shape, dispatch logic, and tool
contracts — they're additive.

---

## Open items

### Envelope

- **Discriminator key:** `"action"` (matches today) vs `"tool"`. Keep `"action"`.
- **Thinking placement:** top-level sibling to `action`. Simpler.
- **Legacy envelope recovery:** accept old `action_input` wrapper when present,
  log telemetry counter. Remove after one deprecation cycle.

### Parser

- **Auto-close aggressiveness:** close strings? arrays? Decide by testing
  against regression corpus. Conservative default: close `{`, `[`, `"` only at
  EOF.
- **Fence-strip patterns:** exact regexes — handle ` ```json `, ` ``` `,
  leading/trailing whitespace. Cover in tests.

### Reasoner

- **Throttle thresholds:** 100ms / 256 bytes as starting point. Measure, adjust.
- **Live thinking:** emit `thinking` from partial parses incrementally, or
  wait for final? Wait initially; upgrade if UX demands.
- **Reprompt budget:** 1 (same as today).

### Tool migration

- **Audit depth:** which tools take `*_json:` today. Grep during Phase 2 kickoff.
- **Schema format for nested types:** keyword list supports `:list`, `:map`,
  nested keyword lists. Confirm `extract_and_coerce` handles them.

### Deprecation

- **`:structured` sunset window:** declare after 2 weeks of `:tagged` in
  production without issue.
- **Agents depending on `:structured`:** audit `.rho.exs` and demo configs.

---

## File-change summary

### Phase 0
```
[edit]   lib/rho/mount_registry.ex
[create] test/rho/mount_registry_load_test.exs
```

### Phase 1
```
[create] lib/rho/parse/lenient.ex
[create] lib/rho/reasoner/tagged.ex
[create] lib/rho/reasoner/tagged/dispatch.ex
[create] lib/rho/reasoner/tagged/prompt_section.ex
[create] lib/rho/reasoner/tagged/coerce.ex
[create] test/rho/parse/lenient_test.exs
[create] test/rho/reasoner/tagged_test.exs
[create] test/rho/reasoner/tagged/dispatch_test.exs
[create] test/rho/reasoner/tagged/coerce_test.exs
[create] test/fixtures/parse_corpus/
[edit]   lib/rho/reasoner.ex
[edit]   lib/rho/reasoner/direct.ex
[edit]   lib/rho/reasoner/structured.ex
[edit]   lib/rho/agent_loop.ex
[edit]   lib/rho/config.ex
[edit]   .rho.exs
```

### Phase 2
```
[edit]   lib/rho/mounts/spreadsheet.ex         # add_rows, update_cells typed
[edit]   (+ other *_json tools from audit)
```

### Phase 3 (retirement)
```
[delete] lib/rho/reasoner/structured.ex
[delete] lib/rho/structured_output.ex
[delete] test/rho/structured_output_test.exs
```

---

## Success metrics per phase

### Phase 1 (tagged reasoner in production)
| Metric | Target |
|---|---|
| Double-escaped `\"` in tool args | 0 |
| Heuristic recovery hits | 0 |
| Reprompt rate | ≤ `:structured` |
| Token count per turn | ≤ `:structured` |
| Partial-parse CPU per turn | < 2% |
| Task completion parity | yes |
| Field collision incidents | 0 |

### Phase 2 (tool migration)
| Metric | Target |
|---|---|
| JSON-encoded strings in args | 0 for migrated tools |
| Tool success rate | unchanged |
| Tape replay | unaffected |

### Phase 3 (retirement)
| Metric | Target |
|---|---|
| Agents on `:structured` | 0 |
| `Rho.StructuredOutput` references | 0 |
| `detect_implicit_tool`, `_raw`, `lang_to_tool` in codebase | absent |

If any metric regresses, stop and investigate before advancing.

---

## Implementation task list

Tasks are ordered. Each has a clear definition-of-done. Check off as completed.

### Phase 0 — Pre-refactor cleanup

- [ ] **0.1** Read `lib/rho/mount_registry.ex` around `safe_call/4`; confirm
      `function_exported?/3` is called without `Code.ensure_loaded!/1`.
- [ ] **0.2** Add `Code.ensure_loaded!/1` before `function_exported?/3` in
      `safe_call/4`. Handle the case where the module doesn't exist.
- [ ] **0.3** Add regression test `test/rho/mount_registry_load_test.exs` that
      loads a module only at runtime and verifies `safe_call` hits the
      callback correctly.
- [ ] **0.4** Run full `mix test` — no regressions.

### Phase 1 — Lenient parser ✅ DONE (2026-04-05)

- [x] **1.1** Create `lib/rho/parse/lenient.ex` with `parse/1`,
      `parse_partial/1`, `strip_fences/1`, `auto_close/1`.
- [x] **1.2** Implement `strip_fences/1` — handle ` ```json `, ` ``` `, leading
      and trailing whitespace, no fences (idempotent).
- [x] **1.3** Implement `auto_close/1` — scan for `{`, `[`, `"` depth; append
      closers at EOF. Preserve in-string characters correctly (do not count
      `{` inside strings).
- [x] **1.4** Add `Rho.Parse.Lenient` telemetry events
      (`[:rho, :parse, :lenient, :parse]`).
- [x] **1.5** Create `test/rho/parse/lenient_test.exs` — all required cases
      covered (happy-path, fenced, missing closer/bracket, unterminated
      string, deep nesting, braces in strings, escaped quotes, empty,
      idempotence).
- [ ] **1.6** Add property-based tests in
      `test/rho/parse/lenient_property_test.exs` using StreamData:
      - round-trip invariant (valid JSON → parse → same value)
      - prefix safety (any prefix → never crash)
      - fence invariant (fenced = unfenced after strip)
- [x] **1.7** Run `mix test` — all pass (344 tests, 0 failures).

### Phase 1 — Reasoner behaviour hook ✅ DONE

- [x] **1.8** Add `@callback prompt_sections/1` to `lib/rho/reasoner.ex`
      (marked `@optional_callbacks`).
- [x] **1.9** Implement `prompt_sections/1` in `Rho.Reasoner.Direct` — returns
      empty list.
- [x] **1.10** Implement `prompt_sections/1` in `Rho.Reasoner.Structured` —
      wraps existing `prompt_section/1`.
- [x] **1.11** Edit `lib/rho/agent_loop.ex` to call
      `reasoner_mod.prompt_sections(tool_defs)` generically via
      `function_exported?/2` check. Removed `if reasoner == Structured` branch.
- [x] **1.12** Existing reasoner tests still pass.

### Phase 1 — `:tagged` reasoner ✅ DONE

- [x] **1.13** `lib/rho/reasoner/tagged/prompt_section.ex` — renders tool
      list as discriminated variants with few-shot examples.
- [x] **1.14** `lib/rho/reasoner/tagged/coerce.ex` — `extract/2`. Handles
      `:string`, `:integer`, `:float`, `:boolean`, `:map`, `:any`,
      `{:list, inner}`, nested keyword-list schemas. Reports missing
      required fields with field names.
- [x] **1.15** `lib/rho/reasoner/tagged/dispatch.ex` — `decide/2` returns
      `{:final, ...}`, `{:tool, ...}`, `{:unknown_action, ...}`,
      `{:missing_action, ...}`, or `{:invalid_args, ...}`. Supports alt
      discriminators (`tool`, `tool_name`) and alt thinking keys
      (`thought`, `reasoning`).
- [x] **1.16** `lib/rho/reasoner/tagged.ex` — `@behaviour Rho.Reasoner`,
      streams via `ReqLLM.stream_text`, throttles partial-parse
      (100ms / 256B + structural-token guard), emits
      `:text_delta`, `:structured_partial`, `:tool_start`, `:tool_result`,
      `:llm_usage`, `:llm_text` (thinking). Reprompts once on parse/
      dispatch failure via `:tool_step` entries. Same retry policy as
      `:structured` for mid-stream errors.
- [x] **1.17** Slip-recovery path: `action_input` wrapper → promote fields
      into top-level + emit `[:rho, :reasoner, :tagged, :slip_recovery]`
      counter.
- [x] **1.18** Event-payload summarization: lists > 20 items rendered as
      `"<N items>"` in `:structured_partial` events.
- [x] **1.19** Edit `lib/rho/config.ex` — `:tagged` → `Rho.Reasoner.Tagged`.
- [x] **1.20** First real agent migration — `spreadsheet` flipped from
      `:structured` → `:tagged` on 2026-04-05. Rationale: heaviest user of
      `_json`-suffixed args (rows_json, changes_json, levels_json, ids_json
      across add_rows/update_cells/add_proficiency_levels/delete_rows/
      replace_all). Migration note + rationale inline in `.rho.exs`. This
      is our first real-traffic data point — no other agents flipped until
      exit-criteria results are captured in `docs/reasoner-baml-results.md`.

### Phase 1 — Unit tests for `:tagged` ✅ DONE

- [x] **1.21** `test/rho/reasoner/tagged/coerce_test.exs` — primitives
      (string/int/float/bool/map/any), lists, nested objects,
      missing-required, wrong-type, extras dropped, error messages carry
      field names.
- [x] **1.22** `test/rho/reasoner/tagged/dispatch_test.exs` — final_answer,
      tool (with string and list fields), unknown action, missing action
      (incl. null), missing required field, slip-recovery, alt
      discriminators, alt thinking keys.
- [x] **1.23** `test/rho/reasoner/tagged_test.exs` — Mimic end-to-end:
      single-turn final_answer, multi-turn tool → result → final_answer,
      slip recovery, reprompt paths (malformed JSON / unknown action /
      missing arg), markdown fences, prompt injection.

### Phase 1 — Comparison / adversarial tests

- [ ] **1.24** Build `test/support/reasoner_harness.ex` — replays a fixture
      LLM response through a named reasoner with a fake tool_map; returns
      `%{dispatched: ..., heuristic_hits: n, reprompts: n, tokens: n}`.
- [ ] **1.25** `test/rho/reasoner/comparison_test.exs` — each adversarial
      case from the Validation matrix:
      - bare JSON array
      - large array (100+ rows)
      - multi-line bash command
      - python with triple-quoted docstring
      - unicode / emoji
      - markdown-fenced JSON
      - legacy `action_input` wrapper
      - unknown action
      - missing required field
      - extra field
      - null action
      - empty response
      - trailing non-JSON content
      Assert `:tagged` heuristic_hits == 0 and reprompts ≤ `:structured`.
- [ ] **1.26** `test/rho/reasoner/tagged/streaming_test.exs` — partial-parse
      cadence, action-resolved mid-stream, throttle stop, abrupt end.
- [ ] **1.27** `test/rho/reasoner/tagged/concurrency_test.exs` — 100 parallel
      parses, 10 concurrent agents.
- [ ] **1.28** `test/rho/reasoner/tagged/tape_replay_test.exs` — old
      `:structured` tape + new `:tagged` turns coexist.
- [ ] **1.29** `test/rho/reasoner/tagged/property_test.exs` — variant + args
      round-trip under any discriminator, extra keys ignored.

### Phase 1 — Regression corpus

- [ ] **1.30** Grep `_rho/sessions/*/events.jsonl` for assistant messages
      that hit `detect_implicit_tool`, `_raw`, `lang_to_tool`, or parse errors
      under `:structured`.
- [ ] **1.31** Copy ~20 representative examples to
      `test/fixtures/parse_corpus/NNN-description.json` with a
      `fixture.exs` index describing each case.
- [ ] **1.32** `test/rho/reasoner/tagged_corpus_test.exs` — replay each
      fixture, assert `:tagged` dispatches correctly.
- [ ] **1.33** `test/rho/reasoner/structured_corpus_test.exs` — same
      fixtures under `:structured`, record baseline metrics (heuristic hits,
      reprompts, success rate) as a comparison anchor.

### Phase 1 — Coverage + telemetry

- [ ] **1.34** Run `mix test --cover`. `Rho.Parse.Lenient` ≥ 95%,
      `Rho.Reasoner.Tagged` ≥ 95%, dispatch logic at 100%.
- [ ] **1.35** Attach telemetry handlers in a dev helper; run a live agent
      task under `:tagged`; verify events fire with expected shapes.
- [ ] **1.36** Measure partial-parse CPU overhead across 10 real tasks
      (collect via telemetry). Confirm < 2% of turn duration.

### Phase 1 — Integration

- [ ] **1.37** Run an agent end-to-end (CLI) under `reasoner: :tagged` for a
      task using `add_rows` + `bash` + `final_answer`. Confirm completion.
- [ ] **1.38** Re-run the same task under `:structured`. Diff token counts,
      reprompt counts, heuristic-hit counts.
- [ ] **1.39** Document findings in a short markdown note
      (`docs/reasoner-tagged-phase1-results.md`).
- [ ] **1.40** If all exit criteria met, mark Phase 1 complete.

### Phase 2 — Migrate JSON-string-heavy tools

- [ ] **2.1** Grep for `_json:` and `json: :string` in
      `lib/rho/**/*.ex`. Produce the full audit list.
- [ ] **2.2** Per tool, in separate small commits:
      - Update `parameter_schema` to typed shape (e.g.
        `rows: {:list, :map}` or nested keyword list).
      - Rewrite `execute/1` to accept the decoded shape directly.
      - Drop `Jason.decode!` call in the executor.
      - Update tool test(s).
      - Verify under `:tagged` with a replay test.
- [ ] **2.3** Run full `mix test` after each tool migration.
- [ ] **2.4** Run end-to-end agent task that exercises migrated tools.
      Confirm no regression.
- [ ] **2.5** Update `docs/reasoner-tagged-phase1-results.md` with post-
      migration metrics.

### Phase 3 — Retirement

- [ ] **3.1** Audit `.rho.exs` + demo configs for `reasoner: :structured`.
      Migrate each to `:tagged` or `:direct`.
- [ ] **3.2** Add `@deprecated` to `Rho.Reasoner.Structured` and the
      `:structured` atom handling in `Rho.Config`.
- [ ] **3.3** After 2–4 weeks of stable `:tagged` in production, delete:
      - `lib/rho/reasoner/structured.ex`
      - `lib/rho/structured_output.ex`
      - `test/rho/structured_output_test.exs`
      - `Rho.Reasoner.Structured.prompt_section/1` references
- [ ] **3.4** Remove `:structured` from `Rho.Config.resolve_reasoner/1`.
- [ ] **3.5** Grep for `detect_implicit_tool`, `parse_fallback`,
      `lang_to_tool`, `_raw` — confirm none remain.
- [ ] **3.6** Run full `mix test`. Confirm all tests pass.

### Ongoing (cross-phase)

- [ ] **X.1** When new adversarial cases surface in production, add them to
      the regression corpus.
- [ ] **X.2** If `[:rho, :parse, :lenient, :parse]` p99 > 50ms in telemetry,
      open a follow-up for native streaming parser.
- [ ] **X.3** If schema definitions become unwieldy across many tools, open
      a follow-up for `Rho.Schema` DSL.
