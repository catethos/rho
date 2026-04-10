# Schema-Aligned Parsing (SAP) — Implementation Plan

> **Vocabulary note (post-refactor).** This plan was drafted when the
> codebase used `Rho.Reasoner` / `MountRegistry` / "mount hook". Those
> names have since moved: `Rho.Reasoner` → `Rho.TurnStrategy`,
> `Rho.Reasoner.Structured` → `Rho.TurnStrategy.Structured`,
> `MountRegistry` → `PluginRegistry`, and "mount hook" is now a typed
> stage on `Rho.Transformer`. SAP emits `:sap_repairs` operational
> signals on the bus. See `CLAUDE.md` §"Migration from Mount/Memory/Reasoner"
> for the full alias table.

Goal: make the structured reasoner competitive with native tool-use on weak
models and strictly better on strong ones by treating parsing as a
schema-guided *repair* problem, not a syntax-recovery problem.

Reference: https://boundaryml.com/blog/schema-aligned-parsing

## Why

`Rho.StructuredOutput` today is schema-blind: it does quote normalization,
control-char escaping, trailing-comma stripping, markdown extraction, and
brace-scan. That fixes syntax errors. It does not fix *semantic* errors
like `"Amazon"` when the schema wants `["Amazon"]`, or misnamed keys, or
extra yapping prose around valid JSON.

The structured reasoner compensates with ad-hoc heuristics
(`detect_implicit_tool/1`, `resolve_tool_args` bare-string fallback,
code-block → python/bash). These are brittle and domain-specific.

SAP replaces all of that with one principle: **compute the lowest-cost edit
that turns the model's output into a value that conforms to the schema,
using the schema to guide every coercion.**

## Architecture overview

```
lib/rho/sap/
  schema.ex         # canonical schema AST (internal, Rho-owned)
  parser.ex         # top-level parse(text, schema) -> {:ok, value, repairs} | {:error, ...}
  recover.ex        # syntax recovery (thin wrapper over current StructuredOutput)
  extract.ex        # candidate extraction (brace-scan, markdown, yapping strip)
  align.ex          # schema-guided coercion (the new work)
  score.ex          # edit-cost scoring + candidate selection
  repair.ex         # repair struct + telemetry helpers
test/rho/sap/
  parser_test.exs
  align_test.exs
  corpus_test.exs   # regression corpus from production
```

`Rho.StructuredOutput` stays as the syntax-recovery layer. `Rho.SAP` wraps
it and adds schema alignment on top. Nothing is replaced wholesale.

---

## Context: pre-production

Rho is not yet deployed. That changes the economics of this plan
significantly. Most of what would otherwise be Phase 0 — corpus
harvesting, baseline telemetry, shadow-mode harness, flag-gated
rollout, ≥5% improvement threshold — exists to protect live users
during a switchover. No users, no switchover, no protection needed.

The feedback loop is `mix test` and dev runs, not production sessions.
The "corpus" is `test/rho/reasoner/structured_corpus_test.exs` plus
whatever breakage shows up in dev. Rollback is `git revert`.

This reframes SAP from "multi-phase rollout program" to "focused
refactor to cement the right abstraction *before* traffic arrives, so
we don't accumulate corpus-shaped tech debt and face a flag-gated
rewrite later."

Phases below are sequenced for that pre-prod reality. Deferred phases
(7 streaming rework, 7.5 multi-action, 10 validation loop) stay
deferred until real usage proves they matter.

---

## Phase 0 — Code-hygiene prerequisites (lightweight)

Traffic-dependent prerequisites are dropped. Only code-hygiene items
that SAP genuinely needs remain.

- **Audit `parameter_schema` completeness.** Grep every `parameter_schema:`
  in `lib/rho/tools/**` and `lib/rho/mounts/**`. Every field must carry
  `:type`; ideally `:required`, `:enum`, `:doc`. Fields without `:type`
  break alignment — fix those first. This is just code hygiene, do it
  regardless.
- **Decide where `final_answer`'s schema lives.** Today hardcoded as
  `{answer: string}`. SAP models it as just another union variant — need
  a config seam (agent-level in `.rho.exs`) before Phase 1.
- **Clarify `Rho.Reasoner.Tagged` scope.** Tagged reasoner shipped per
  memory. Decide: does SAP apply to both Structured *and* Tagged, or
  only Structured? Document in a one-liner.
- **Fix `MountRegistry.safe_call/4`'s `function_exported?/3`** —
  called without `Code.ensure_loaded!/1` first, silently fails. Fix
  *before* SAP so the bug doesn't masquerade as a SAP regression.
- **`detect_implicit_tool/1` archaeology.** This hard-codes the hiring
  demo (`"levels"` key → `add_proficiency_levels`). Before deleting it
  in Phase 8, fix the hiring demo prompt or tool schema so it no longer
  needs the heuristic. Otherwise Phase 8 regresses that demo.

### Decisions to lock down before coding

- **Discriminator alias policy.** Today accepts `action`/`tool`/`tool_name`/
  `name` and `action_input`/`tool_input`/`parameters`/`args`/`input`.
  Recommendation: keep all as fuzzy-aliases with logged repairs on
  non-canonical keys.
- **Hard caps on work.** Pathological inputs can explode
  candidates × fields × edit-distance. Set upper bounds:
  max candidates (5), max alignment attempts (20), max wall-clock per
  parse (50ms). Fail open to `{:raw_response, text}`.
- **Nested-JSON-string decoding.** `normalize_args/1` auto-decodes
  today. Some tools may rely on that. Audit callers before Phase 8
  deletes it; replicate via `:decode_nested_json` repair.
- **Streaming vs. alignment scope.** Alignment needs a complete JSON
  value. Partial parser does syntax-recovery + prefix streaming only.
  Full alignment runs post-stream.

**Deliverable checklist:**
- [ ] `parameter_schema` audit report (file-by-file gaps)
- [ ] `final_answer` config seam design note
- [ ] Tagged reasoner scope decision documented (one line)
- [ ] `safe_call/4` `Code.ensure_loaded!` fix
- [ ] Hiring demo no longer relies on `detect_implicit_tool`

---

## Phase 1 — Schema AST (foundation)

Define an internal schema representation the aligner walks. Kept
deliberately minimal; does not attempt to be BAML IR.

```elixir
defmodule Rho.SAP.Schema do
  @type t ::
          {:string}
          | {:int}
          | {:float}
          | {:bool}
          | {:enum, [String.t()]}
          | {:list, t()}
          | {:map, t(), t()}
          | {:object, [{field :: String.t(), t(), required :: boolean()}]}
          | {:union, [{tag :: String.t(), t()}]}   # discriminated union (final_answer | tool_a | tool_b)
          | {:any}

  @spec from_tool_param_schema(keyword()) :: t()
  def from_tool_param_schema(schema), do: ...

  @spec action_union(tool_defs, final_answer_schema :: t()) :: t()
  def action_union(tool_defs, final_schema), do: ...
end
```

Build once per turn in `Reasoner.Structured.run/2` and pass through
everywhere. Do not walk `tool.parameter_schema` on each parse attempt.

**Deliverable:** `Rho.SAP.Schema` + tests covering conversion from existing
`parameter_schema` keyword format.

---

## Phase 2 — Candidate extraction

Pull one or more JSON-shaped candidates out of noisy text.

```elixir
defmodule Rho.SAP.Extract do
  @spec candidates(String.t()) :: [String.t()]
end
```

Strategies, in order:
1. Whole text parses as JSON → one candidate.
2. Fenced code blocks (```json ... ```) → candidates.
3. Outer brace-scan (first `{` to each matching `}` position) → candidates.
4. Multiple top-level JSON objects → merged candidate + individual candidates.

Already mostly implemented in `StructuredOutput`. Just needs to return
*all* viable candidates instead of the first that decodes, so the scorer
can pick the best-aligned one.

**Deliverable:** `Rho.SAP.Extract` returning a list of candidate strings.

---

## Phase 3 — Syntax recovery (reuse)

Wrap existing `Rho.StructuredOutput` normalizations:
- quote normalization (curly, single)
- control-char escaping
- trailing-comma stripping
- unquoted-key patching (NEW — JS/Python-style unquoted keys are common)
- comment stripping (NEW — LLMs emit `// ...` in JSON)

> **UTF-8 safety:** any string-shortening repair (yapping strip, ellipsize,
> truncate-on-cap) must iterate by grapheme/codepoint, never by byte
> offset. Cross-project lesson from `tao` (Rust): byte-slicing multi-byte
> text silently produced invalid UTF-8 that masqueraded as parse failures
> downstream. In Elixir: `String.slice/2`, `String.graphemes/1`, not
> `binary_part/3`.

```elixir
defmodule Rho.SAP.Recover do
  @spec normalize(String.t()) :: [String.t()]  # returns all passing variants
end
```

Each candidate from Phase 2 goes through these recoveries, producing a set
of syntactically valid JSON values. If none parse, the candidate is dropped.

**Deliverable:** `Rho.SAP.Recover` with two new recoveries (unquoted keys,
comments).

---

## Phase 4 — Schema-guided alignment (the core)

Given a parsed JSON value and the target schema, produce the nearest
schema-conformant value and a list of repairs applied.

```elixir
defmodule Rho.SAP.Align do
  @spec align(json_value, Schema.t(), opts()) ::
          {:ok, value, [Repair.t()]} | {:error, [Repair.t()], reasons}
end
```

### Alignment rules (coercion table)

| From           | Target schema   | Coercion                                    |
|----------------|-----------------|---------------------------------------------|
| `"Amazon"`     | `{:list, _}`    | wrap → `["Amazon"]`                         |
| `["x"]`        | `{:string}`     | unwrap first if singleton                   |
| `"42"`         | `{:int}`        | `String.to_integer/1`                       |
| `"3.14"`       | `{:float}`      | `String.parse/1`                            |
| `42`           | `{:string}`     | `to_string/1`                               |
| `"true"`       | `{:bool}`       | parse                                       |
| `"Foo"`        | `{:enum, vals}` | fuzzy match (case-insensitive, then prefix) |
| `nil`          | required field  | attempt default, else repair error          |
| extra keys     | `{:object, _}`  | drop, emit repair                           |
| missing key    | `{:object, _}`  | try alt spellings, else null if optional    |
| misnamed key   | `{:object, _}`  | Levenshtein <= 2 match to schema key        |
| nested JSON-in-string | any       | try decoding string, re-align               |

### Discriminated union alignment (the reasoner's action type)

The action schema is `{:union, [{"final_answer", ...}, {"bash", ...}, ...]}`.
Input like:
```json
{"action": "bash", "action_input": {"cmd": "ls"}}
```
Aligns by:
1. Read `action` field → selects union variant.
2. Align `action_input` against the selected variant's schema.
3. If `action` is unknown, try fuzzy match against variant tags.
4. If fuzzy-matched, add a `:variant_renamed` repair.

### Repair record

```elixir
defmodule Rho.SAP.Repair do
  defstruct [:kind, :path, :from, :to, :cost]
  # kinds: :wrap_list, :unwrap_singleton, :coerce_type, :fuzzy_key,
  #        :fuzzy_variant, :drop_extra_key, :fill_optional_null,
  #        :decode_nested_json, :strip_comment, :fix_quotes
end
```

**Deliverable:** `Rho.SAP.Align` + exhaustive alignment tests. Each
coercion rule gets a test.

---

## Phase 5 — Scoring & selection

When multiple candidates survive extraction+recovery+alignment, pick the
one with the lowest total repair cost.

```elixir
defmodule Rho.SAP.Score do
  @spec cost([Repair.t()]) :: non_neg_integer()
  @spec select([{value, [Repair.t()]}]) :: {value, [Repair.t()]} | :none
end
```

Cost weights (initial, tunable from corpus data):
- `:coerce_type` = 1
- `:wrap_list` / `:unwrap_singleton` = 1
- `:fuzzy_key` = 2 (per edit distance unit)
- `:fuzzy_variant` = 3
- `:drop_extra_key` = 1
- `:fill_optional_null` = 0
- `:decode_nested_json` = 2
- syntax repairs (from Phase 3) = 1 each

Hard cap: if total cost > `max_cost` (default 20), return `:error`. This
prevents pathological "aligned" garbage.

**Deliverable:** `Rho.SAP.Score` + selection tests.

---

## Phase 6 — Public parser entrypoint

```elixir
defmodule Rho.SAP.Parser do
  @spec parse(text :: String.t(), Schema.t(), opts()) ::
          {:ok, value, [Repair.t()]}
          | {:partial, [Repair.t()]}   # streaming, not yet parseable
          | {:error, reason :: term()}

  def parse(text, schema, opts \\ []) do
    text
    |> Extract.candidates()
    |> Enum.flat_map(&Recover.normalize/1)
    |> Enum.flat_map(&decode_to_json/1)
    |> Enum.map(&Align.align(&1, schema, opts))
    |> Enum.filter(&match?({:ok, _, _}, &1))
    |> Score.select()
    |> wrap_result()
  end
end
```

Emit `:telemetry` events:
- `[:rho, :sap, :parse, :stop]` — `%{duration_us, repair_cost, candidates_tried}`
- `[:rho, :sap, :parse, :exception]` — parse failures
- `[:rho, :sap, :repair]` — one per repair applied (for corpus mining)

**Deliverable:** `Rho.SAP.Parser.parse/3` + telemetry + integration test.

---

## Phase 7 — Schema-aware streaming (IN SCOPE)

Progressive rendering is the reason the structured reasoner exists
over native tool-use. Specifically: when a tool's `action_input`
contains a list (skills, framework items, rows), the UI must render
list elements **one by one as they stream**, not wait for the full
JSON object to close. Otherwise the user can't tell the system is
working.

### Current streaming behavior

`Reasoner.Structured.stream_with_retry/5` already accumulates tokens
and calls `StructuredOutput.parse_partial/1` after every token,
emitting `:structured_partial` with the best-effort parsed map. Two
problems:

1. **Subscribers get the whole map every tick** — no delta, no
   "element N was just added." UI has to diff the map itself to
   decide what to render.
2. **Called every token** — the O(n²) concern from the BAML critique.
   For a long skill list this runs parse+auto-close on growing text
   once per token.

### What Phase 7 adds

Schema-aware partial events that tell subscribers *what just
appeared*, not just *what the whole thing looks like so far*:

- `:thinking_delta` — `thinking` field characters as they stream,
  before the field closes.
- `:action_detected` — emitted once when the `action` field closes
  (so the UI can pick a renderer).
- `:action_input_field_started` — `%{path: ["skills"], type: :list}`
  when a field under `action_input` opens.
- `:action_input_list_item` — `%{path: ["skills", 3], value: {...}}`
  when a list element closes inside `action_input`. This is the
  key event for your skill-framework case — every new skill in the
  array emits one event, letting the UI append a card progressively.
- `:action_input_field_closed` — field complete, final aligned value.

### Implementation sketch

```elixir
defmodule Rho.SAP.Stream do
  # Incremental, schema-guided tokenizer + event emitter.
  # State machine tracks: in-string, escape, current path, current
  # partial value, current list index.
  @spec feed(state, chunk :: String.t(), schema :: Schema.t()) ::
          {new_state, [event()]}
end
```

The state machine walks the JSON character-by-character, maintains a
`path` stack matching the schema, and emits events at structural
boundaries (string close, list-element close, object close). Because
the schema is known, each path has a type — the emitter can align
each just-closed value against its field's schema *immediately* and
emit the aligned result, not the raw JSON token.

Full alignment of the complete value still runs post-stream (Phase 6)
as the authoritative parse — streaming events are advisory for UX.
Post-stream aligned value is the one that goes into the tape.

### Throttling

Not per-token. Emit events at structural boundaries only (string
close, list-element close, field close). For very long strings in a
single field (e.g. a 5000-char `answer`), throttle `:thinking_delta`/
string-content deltas to 100ms or 256-byte chunks to keep LiveView
patch rate sane.

### Cancellation

Thread a cancel ref through the streaming path — user-cancel,
step-budget-exhausted, or wall-clock timeout must be able to abort
mid-stream cleanly. Check the ref between chunks; on cancel, return
the partial state so the tape can record what was produced before
abort.

### Backward compat

Keep `:structured_partial` emitted (current subscribers rely on it),
add the new `:action_input_*` events alongside. UI migrates field-by-
field: skill/framework list rendering uses `:action_input_list_item`
(progressive), other views keep consuming the whole-map event.

**Deliverable:** `Rho.SAP.Stream` state machine + new event types +
throttle + cancel plumbing + UI migration for the skill/framework
list-rendering path (the one that drove this phase). Use the schema to decide *when* to emit partial
events:
- Emit `:thinking_delta` as soon as the `thinking` field string has
  content, don't wait for the full object.
- Emit `:action_detected` once the `action` field closes.
- Emit `:action_input_partial` with the aligned-so-far input.

Throttle parse_partial calls: every 200ms or 512 bytes, not every token.
Addresses the O(n²) concern from the BAML critique.

**Cancellation:** thread a cancel signal through the streaming parse path
— user-cancel, step-budget-exhausted, or wall-clock timeout must be able
to abort mid-stream cleanly. Cross-project lesson from `tao` (Rust): its
streaming tool parser uses `tokio::select!` on a `CancellationToken` so a
cancel short-circuits the accumulator loop. Elixir equivalent: run the
parse under a `Task` with a monitored process + timeout, or check a
shared cancel ref between chunks. The Phase 0 50ms wall-clock cap covers
the pathological-input case; this is the user/budget-initiated cancel
case.

**Deliverable:** streaming parser + throttle + new event types + cancel
plumbing.

---

## Phase 7.5 — Multi-action schema (DEFERRED)

Deferred until real traffic shows the 1-action-per-turn latency is
actually costly. This phase is a concurrency change riding on SAP's
coattails — concurrent `before_tool`/`after_tool` hooks, tool
isolation decisions, signal-bus ordering, tape compaction. Evaluate
against `Reasoner.Direct`'s existing parallelism in its own plan
doc. Do not bundle with the SAP refactor.

Original sketch retained below for when it's time:

Reason: `Direct` runs tool calls in parallel via `Task.async/1`, `Structured`
forces one action per LLM round-trip. For a read-heavy turn (3 reads, 1
reason, 1 write), that's 5 round-trips vs. 2. Latency multiplier is real
and paid every turn.

The SAP union schema makes this essentially free to add: the action type
becomes a *list* of variants, not a single variant.

### Schema change

```elixir
# Before (conceptual):
action_schema = {:union, [final_answer, bash, fs_read, ...]}

# After:
action_schema = {:object, [
  {"thinking", {:string}, false},
  {"actions", {:list, {:union, [final_answer, bash, fs_read, ...]}}, true}
]}
```

### Prompt schema (what the LLM sees)

```
{
  thinking: string,
  actions: Action[]   // 1+ actions; use one per turn unless independent
}

Action variants:
- final_answer: { answer: string }
- bash: { cmd: string }
- fs_read: { path: string, offset?: int }
...
```

Guidance in the prompt: "emit multiple actions only when they don't
depend on each other's outputs. Prefer one action when a later step
depends on an earlier step's result."

### Execution semantics

In `Reasoner.Structured.run/2` after SAP alignment:

```elixir
%{"thinking" => thinking, "actions" => actions} = aligned_value

case actions do
  [%{"name" => "final_answer", "input" => %{"answer" => a}}] ->
    emit_thinking(thinking)
    {:done, %{type: :response, text: a}}

  actions ->
    # Execute non-final actions in parallel, mirror Direct reasoner shape
    emit_thinking(thinking)
    execute_parallel(actions, tool_map, runtime)
end
```

Rules:
- If `final_answer` appears alongside other actions, execute others
  first; `final_answer` is applied on next turn only if no tool changed
  state. Simpler rule: **`final_answer` must be the sole action** — if
  mixed, drop `final_answer` and treat as tool-only turn, add repair
  `:final_answer_mixed_with_tools`.
- Parallel execution mirrors `Reasoner.Direct.handle_tool_calls/4`:
  `Task.async` per action, `Task.await_many` with 5-minute timeout,
  `before_tool`/`after_tool` lifecycle per call.
- Tool results are batched into a single `:tool_step` entry (one
  assistant message + one user message containing all results keyed by
  call_id), so the tape preserves correct provenance.

### Tape shape

Extend `build_tool_step_from_result` to handle N calls:

```elixir
%{
  type: :tool_step,
  assistant_msg: ReqLLM.Context.assistant(Jason.encode!(%{
    thinking: thinking, actions: actions_log
  })),
  tool_results: [ReqLLM.Context.user(batched_results_text)],
  structured_calls: Enum.map(actions, &{&1.name, Jason.encode!(&1.input)}),
  tool_calls: [],
  response_text: nil
}
```

Replay sees one assistant turn + one user turn with all results — same
pattern as `Direct`'s multi-tool_calls single `tool_step`.

### Backward compatibility

Accept both shapes during alignment:
- `{"action": "bash", "action_input": {...}}` → coerce to
  `{"actions": [{"name": "bash", "input": {...}}]}` (add repair
  `:single_action_wrapped`).
- `{"actions": [...]}` → native.

This lets old prompts/fixtures work unchanged and lets us keep the same
parser in shadow mode.

### Guardrails

- Max `N` actions per turn (default 5) — cap enforced by alignment,
  excess dropped with repair log. Prevents runaway fan-out.
- Actions must be distinct (dedupe by `{name, input}` hash) — same repair.
- Terminal tools (`finish`, `end_turn`, `create_anchor`, `clear_memory`)
  must be sole actions, same rule as `final_answer`.

**Deliverable:** multi-action alignment + parallel executor + tape
builder. All existing `structured_corpus_test.exs` fixtures still pass
via the single-action wrapping coercion.

---

## Phase 8 — Wire into `Rho.Reasoner.Structured`

This is where SAP pays off. Rewrite `parse_action/2` and friends:

### Before
```elixir
defp parse_action(text, tool_map) do
  case parse_json_action(text) do
    {:ok, action} -> resolve_action(action, tool_map)
    :miss -> parse_fallback(text, tool_map)
  end
end
```

### After
```elixir
defp parse_action(text, action_schema, tool_map) do
  case Rho.SAP.Parser.parse(text, action_schema, max_cost: 15) do
    {:ok, %{"action" => name, "action_input" => input}, repairs} ->
      emit_repairs(repairs)
      classify_action(name, input, tool_map)

    {:error, _reason} ->
      {:raw_response, text}
  end
end
```

Changes in `Rho.Reasoner.Structured`:

1. **Build `action_schema` once per turn** in `run/2`:
   ```elixir
   action_schema = Rho.SAP.Schema.action_union(tool_defs, final_answer_schema)
   ```

2. **Delete these functions** (SAP absorbs them):
   - `parse_json_action/1`
   - `extract_action_fields/1` → becomes `Align.align` with union schema
   - `resolve_action/2` → becomes `classify_action/3` (variant already picked)
   - `resolve_tool_args/3` → alignment handles bare-string coercion
   - `normalize_args/1` → alignment handles nested-JSON-string decoding
   - `detect_implicit_tool/1` → dies (domain leak)
   - `parse_fallback/2`'s code-block branch → moves to an opt-in mount hook or dies
   - `extract_code_block/1`, `lang_to_tool/1`, `code_tool_args/2` → same

3. **Keep `execute_action/4` single-action for now** — Phase 7.5
   (multi-action) is deferred. SAP still returns a single aligned
   action; the execute path stays as-is except for carrying the repair
   log through.

4. **Drop the re-prompt correction branch** in `{:raw_response, text}` — if
   SAP returns `:error` after all repair attempts, the input truly is
   unparseable, and we fall through to a single bounded correction with
   the repair log attached (so the LLM sees *what* was wrong, not just
   "please use JSON").

5. **Add per-turn repair telemetry** to the emit stream for the UI:
   ```elixir
   emit.(%{type: :sap_repairs, repairs: repairs, cost: cost})
   ```

6. **No duplicate parse path, no flag.** SAP replaces the old
   `parse_action` in place. Delete the old functions in the same
   commit. No `parse_action_v2/parse_action_legacy` pair, no
   `reasoner_sap` config flag. Git is the rollback. Cross-project
   lesson from `tao` (Rust): its `run_agent`/`run_agent_streaming`
   duplication rotted into 90% copy-paste before being unified via a
   `ToolGetter` trait. Avoid the trap by not forking in the first
   place.

**Deliverable:** structured reasoner ~40% smaller, no domain heuristics,
all fallback logic in one place, old path deleted (not deprecated).

---

## Phase 9 — Synthetic corpus + cost-weight tuning

No production logs exist yet. The corpus is:
1. Every input already pinned by `test/rho/reasoner/structured_corpus_test.exs`
   (these cover the failure modes that motivated the current heuristics).
2. Hand-authored fixtures for each alignment rule in the Phase 4 table
   — one positive + one negative per rule.
3. Any LLM output that breaks during dev runs — add as a fixture the
   moment you hit it.

```
test/rho/sap/corpus/
  bare_string_for_list.json
  nested_json_string_args.json
  misnamed_keys.json
  yapping_prefix.json
  unknown_action_fuzzy_match.json
  ...
```

Each fixture: `{input_text, schema_name, expected_value, expected_repairs}`.

Run as a property-style suite; tune cost weights until all fixtures pass
and no false positives appear on "genuinely garbage" fixtures.

Weights are provisional until real traffic lands. Commit to re-tuning
once the system sees ≥1000 sessions.

**Deliverable:** `corpus_test.exs` + ≥20 synthetic/dev fixtures.

---

## Phase 10 — Validation loop (deferred until real traffic)

Deferred. Only build if post-deploy metrics show cases that alignment
accepts but tools still reject. If after rollout some misalignments
still slip through:

- Add a post-align validator that type-checks the aligned value against
  the schema a second time.
- On validation failure, feed the *repair log + validation error* back to
  the LLM as a structured correction (max 2 attempts per turn).

Only do this if real traffic shows cases that alignment accepts but tools
still reject. Don't build it speculatively.

### Error classification: retryable vs. terminal

When wiring validation/correction, classify the failure before retrying:

- **SAP `:error` (parse/alignment failure)** → retryable within the
  correction budget. Feed repair log back to LLM, max 2 attempts/turn.
- **Tool rejects aligned value** → retryable once with the validation
  error as feedback.
- **Context overflow / `max_tokens` / upstream 4xx on prompt size** →
  NOT retryable. Route to compaction, not correction. A re-prompt with
  a longer repair log only makes the overflow worse.
- **Provider 5xx / rate-limit / timeout** → retryable via the existing
  provider retry layer, not SAP's correction loop.

Cross-project lesson from `tao` (Rust): its `is_retryable_error/1`
explicitly excludes context-overflow from the retry set because the
right remediation is compaction, and naive retry amplifies the problem.
Mirror that distinction in Rho's correction branch.

---

## Testing strategy per phase

| Phase | Test focus |
|---|---|
| 1 | Schema AST construction from every existing tool's `parameter_schema` |
| 2 | Extraction handles yapping, fenced blocks, brace-scan, merged objects |
| 3 | Recovery: unquoted keys, JSON comments, control chars |
| 4 | Every coercion rule in the table has a positive + negative test |
| 5 | Candidate selection picks lowest cost; hard cap rejects garbage |
| 6 | End-to-end parse across synthetic fixtures + any dev-run breakage |
| 7 | List-item events fire per-element mid-stream (skill-framework case); throttle works; cancel mid-stream is clean |
| 7.5 | Multi-action alignment, backward-compat wrapping, parallel executor, guardrails |
| 8 | Structured reasoner tests pass unchanged; new tests for SAP integration |
| 9 | Corpus regression suite pins behavior |

Keep `test/rho/reasoner/structured_corpus_test.exs` green throughout — it's
the acceptance bar.

---

## Rollout sequencing (pre-production)

No flag gate, no shadow mode, no rollback window — we're pre-traffic.
Git is the rollback.

1. **Phases 0–6** land as a unit: prerequisites + schema + extract +
   recover + align + score + parser. No wiring into the reasoner yet.
2. **Phase 8** swaps `parse_action/2` in-place inside
   `Reasoner.Structured`, deletes the old heuristic functions in the
   same commit, and updates every fixture in
   `test/rho/reasoner/structured_corpus_test.exs` to stay green.
3. **Phase 7** (schema-aware streaming) lands next, driven by the
   skill/framework list-rendering UX. The `:action_input_list_item`
   event is the acceptance bar — skills must render one-by-one.
4. **Phase 9** extends the corpus from existing fixtures + any
   breakage hit in dev. No production harvest.
5. **Phases 7.5, 10** stay deferred. Revisit once the system has
   real usage and we know whether multi-action latency or correction
   loops are actually load-bearing.

If something regresses in dev: `git revert` the Phase 8 commit, fix
the alignment rule, re-land. No user-facing risk.

---

## Non-goals

- **Not** replacing `ReqLLM.Tool.parameter_schema` keyword format. SAP
  reads it; tools don't change.
- **Not** vendoring BAML's Rust parser. Pure Elixir. NIF is a later
  perf/robustness upgrade if needed — same conclusion as the BAML
  critique doc.
- **Not** changing provider adapters or the `Direct` reasoner. SAP is
  scoped to `Structured` (and any future prompt-based reasoner).
- **Not** changing the tape/event model beyond adding `:sap_repairs`.

---

## Open questions

1. **Fuzzy-variant threshold**: what Levenshtein distance is "obviously a
   typo for `bash`" vs. "model hallucinated a tool"? Start with distance
   2 and tune from dev-run breakage. Revisit once there's real traffic.
2. **Nested-JSON-string decoding depth**: LLMs sometimes produce
   `action_input: "{\"cmd\":\"ls\"}"`. Decode once. Decoding recursively
   risks ambiguity — don't.
3. **`any` schema fields**: some tool params are untyped maps. Align
   passes them through unchanged. Acceptable?
4. **Should alignment ever mutate values silently, or always via repair
   log?** Always via log. No silent coercion. Observability over magic.
