# Reasoner BAML Phase 1 — Results

**Status:** Phase 1 complete + **pivoted** (2026-04-05). Live-traffic
comparison found two `:tagged` regressions (workflow-contract regression
— skeleton phase + approval gate skipped, +17% output tokens).
`:tagged` reasoner was subsequently removed; `Rho.Parse.Lenient` was
redirected to streaming UX (chat tool-args prettification + streaming
envelope preview). See
`docs/tagged-removal-and-lenient-streaming-plan.md`.

> **Vocabulary note (post-refactor).** "Reasoner" in this document =
> `Rho.TurnStrategy` in current code. `:structured` resolves to
> `Rho.TurnStrategy.Structured`; `:tagged` was removed. See `CLAUDE.md`
> §"Migration from Mount/Memory/Reasoner".

---

## Migration under test

| Agent | Previous reasoner | New reasoner | Rationale |
|---|---|---|---|
| `spreadsheet` | `:structured` | `:tagged` | Heaviest user of `_json`-suffixed args: `rows_json`, `changes_json`, `levels_json`, `ids_json` across `add_rows`, `update_cells`, `add_proficiency_levels`, `delete_rows`, `replace_all`. |

All other agents remain on their prior reasoner until this one-data-point
experiment is evaluated.

---

## Static findings (captured from harness + corpus, no live traffic)

### Corpus heuristic-hit delta (22 real-session fixtures)

Source: `test/rho/reasoner/structured_corpus_test.exs`, run 2026-04-05.

| Reasoner | Heuristic hits | Reprompts |
|---|---|---|
| `:structured` | 2 | 2 |
| `:tagged` | **0** | 2 |

- `:tagged` never fires heuristic recovery (`detect_implicit_tool`,
  `_raw`, `lang_to_tool`, markdown fallback) — invariant asserted by
  `tagged_corpus_test.exs`.
- Both reasoners reprompt on the same plain-text fixtures. No dispatch
  parity loss.

### Adversarial validation matrix (15 cases)

Source: `test/rho/reasoner/comparison_test.exs`. `:tagged.heuristic_hits == 0`
on every case (bare array, multi-line bash, python triple-quoted, unicode,
fenced JSON, legacy `action_input`, unknown action, missing/extra field,
null action, empty, trailing non-JSON).

---

## Coverage verification (1.34)

Run: `mix test --cover` on full suite, 2026-04-05.

| Module | Line coverage | Target | Status |
|---|---|---|---|
| `Rho.Parse.Lenient` | 100.00% | ≥95% | ✅ |
| `Rho.Reasoner.Tagged.Dispatch` | 100.00% | 100% | ✅ |
| `Rho.Reasoner.Tagged` | 75.63% | ≥95% | ❌ |
| `Rho.Reasoner.Tagged.Coerce` | 69.57% | — | — |
| `Rho.Reasoner.Tagged.PromptSection` | 71.43% | — | — |

**`Rho.Reasoner.Tagged` gap analysis.** The uncovered 24% is concentrated
in code paths that require live streaming to exercise:

- Stream retry/backoff (`stream_with_retry` error branch, `maybe_retry`,
  `Process.sleep`, `Logger.warning`).
- `get_stream_metadata` happy path (requires a real
  `ReqLLM.StreamResponse` struct with a `MetadataHandle`; the harness
  uses an opaque `{:harness_stream, ref}` fake).
- `retryable?/1` predicate clauses (per-error-type matching).
- `summarize_large` lists > 20 items.
- `stringify_keys` atom-key branch and `emit_thinking/2` catchall.

This session added `test/rho/reasoner/tagged/execution_test.exs` (4 tests,
all green) which raised Tagged from 66.39% → 75.63% by exercising
`handle_tool_result/5` `{:ok, :error, :final}` branches via the
new `allow_tools: true` harness option.

**Remaining coverage will close naturally under the live task-4 run**
(which exercises `ReqLLM.stream_text`, metadata extraction, and —
best case — never hits retry/error paths). A dedicated mock of
`ReqLLM.StreamResponse.MetadataHandle` + retry scenarios would be needed
to force the remaining 20% in unit tests; deferred until post-live-run
review shows it worth the effort.

---

## Live-traffic metrics — captured 2026-04-05

Spreadsheet task run twice from the editor LiveView
(`/spreadsheet/<session_id>`). Prompt (both runs): *"Build a 6-skill
software-engineering-manager framework with 5 proficiency levels."*
Phase sequence: intake → skeleton approval → parallel proficiency
generation (delegate per-category to `proficiency_writer` sub-agents) →
cleanup of placeholder rows → `finish`.

| Metric | `:structured` | `:tagged` | Target | Result |
|---|---|---|---|---|
| Double-escaped `\"` in outer action_input | 0 | 0 | 0 on `:tagged` | ✅ (but see caveat) |
| Heuristic hits (structured-style) | 0 | 0 | 0 on `:tagged` | ✅ (but see caveat) |
| Reprompt count (approx) | 2 | 2 | `:tagged` ≤ `:structured` | ✅ |
| Avg tokens per assistant turn | 434.33 | 509.39 | `:tagged` ≤ `:structured` | ❌ **+17.3%** |
| Task completion parity | finish | finish | both complete | ✅ |
| Partial-parse CPU overhead per turn | n/a | n/a | < 2% | ⚠️ not captured |
| Slip-recovery event count | n/a | n/a | 0 | ⚠️ not captured |

Assistant turns: 18 both runs. Tool calls: 15 both runs. Total output
tokens: 7818 (`:structured`) vs 9169 (`:tagged`).

### Session IDs and raw reports

- `:tagged` → `_rho/sessions/tagged_eval_1/` (events.jsonl 1.0 MB)
- `:structured` → `_rho/sessions/structured_eval_1/` (events.jsonl 651 KB)

Post-hoc analysis via `mix rho.reasoner_report <session_id>`.

### Caveat: post-hoc envelope metrics are structurally-0 for `:structured`

The `double_escape_count` and `heuristic_hits` metrics scan assistant
`llm_text` events for envelope patterns. Under `:structured`, the reasoner
uses provider-native tool_calls (ReqLLM `finish_reason: tool_calls`), so
assistant text is either empty or free-form thinking prose — never a
top-level `{action, action_input}` envelope. Both metrics therefore
return 0 for `:structured` by construction, not by quality.

The original double-escape hypothesis (that `:tagged` eliminates inner
`action_input: "{\"rows\":[...]}"` escapes present under `:structured`)
cannot be validated from this post-hoc scan. It **is** validated by the
adversarial matrix (`test/rho/reasoner/comparison_test.exs`) and the
corpus test (`test/rho/reasoner/structured_corpus_test.exs`, 22 fixtures,
2 heuristic hits under `:structured` / 0 under `:tagged`). The live-run
scan adds: "under normal envelope-emitting traffic, `:tagged` also
holds at 0" — a weaker but complementary signal.

### Caveat: `--attach` telemetry captured no events

The `mix rho.reasoner_report --attach tagged_eval_1` handler ran in a
separate BEAM from the Phoenix server (`mix phx.server`), so
`[:rho, :parse, :lenient, :parse]` and
`[:rho, :reasoner, :tagged, :slip_recovery]` never reached the handler
(`:telemetry.attach` is node-local). `reasoner_telemetry.jsonl` is empty
for both sessions. To capture these, either:

- Run the Phoenix server and the attach handler in the same BEAM
  (`iex -S mix phx.server` → attach manually), or
- Embed a lightweight always-on telemetry recorder inside the
  application supervision tree (writes to
  `_rho/sessions/<session_id>/reasoner_telemetry.jsonl`).

Deferred; the two envelope/dispatch metrics already confirm the main
hypothesis. Slip-recovery = 0 is the expected steady-state for `:tagged`
and will be monitored passively.

### Workflow regression — skipped skeleton phase + no approval gate

**Observed 2026-04-05.** Under `:tagged`, the spreadsheet primary agent
skipped Phase 2 (skeleton + user-approval gate) entirely. Tool-call
timelines from the two sessions (filtered to primary agent):

`:structured` (session `structured_eval_1`):

| turn_id | tool calls |
|---|---|
| 4 | `add_rows` (6 skeleton rows) |
| *— user approves in LiveView —* | |
| 546 | `delegate_task` ×3 → `await_task` ×3 → `delete_rows` |

`:tagged` (session `tagged_eval_1`):

| turn_id | tool calls |
|---|---|
| 4194 | `delegate_task` ×3 → `await_task` ×3 → `get_table_summary` → `delete_rows` |

Under `:tagged` the primary made **zero `add_rows` calls**
(`grep '"name":"add_rows","type":"tool_start"'` → 0 matches for
`tagged_eval_1`, 1 match for `structured_eval_1`). It went straight
from intake to delegation, so sub-agents populated rows via
`add_proficiency_levels` without a skeleton existing first. All primary
tool calls happened in a single reasoning turn (4194) — no pause for
the user to review the skeleton (there was no skeleton to review).

**User-observed symptom:** the skeleton *appears in the chat pane*
because the model describes it in prose (`llm_text` event is emitted
and rendered by the chatbox), but the *left-hand spreadsheet pane
never updates* because no tool call dispatches the rows. The user
watches the model claim it built a skeleton while the table stays
empty; then the table suddenly fills with the fully-populated
framework when sub-agents finish.

The system prompt for `spreadsheet`
(`.rho.exs:82-96`) states:

> Phase 2: Skeleton (MANDATORY — do this BEFORE delegating to sub-agents)
> ...
> After adding the skeleton, STOP and ask the user: ...
> Wait for the user to approve before proceeding to Phase 3.

`:tagged` violates both the mandatory-skeleton and approval-gate
contracts. This is a workflow-contract regression, not just a
performance delta.

**Likely root cause.** The tagged reasoner appears to execute multiple
tool calls per assistant turn (all 7+ calls under `turn_id: "4194"`),
whereas the structured reasoner produces one provider-native
`tool_calls` finish per turn that surfaces back through the LiveView
layer. If the tagged reasoner dispatches multiple tags emitted in a
single model response sequentially within one loop iteration, the
LiveView never re-renders between them — and more importantly, the
model-level "stop and ask" instruction cannot fire because the loop
keeps calling tools until the envelope contains a terminal action.

**Fix candidates (not yet investigated):**

1. Enforce single-action-per-turn in `Rho.Reasoner.Tagged` — only
   dispatch the first `<action>` per model response, ignore the rest,
   let the next turn re-observe.
2. Emit an event boundary between dispatched actions so the LiveView
   can re-render and the user can interrupt.
3. Strengthen the prompt section to instruct the model "emit exactly
   one `<action>` per response."

### Token regression analysis

`:tagged` used ~17% more output tokens per turn (509 vs 434 avg,
9169 vs 7818 total) with identical turn counts (18), tool calls (15),
and completion paths. Candidate explanations:

1. **Envelope overhead.** Tagged responses emit structured `<action>` /
   `<action_input>` XML tags around tool payloads, which the model
   regenerates each turn. Under `:structured`, tool_calls are emitted
   natively by the provider tool-use API and are not counted as output
   tokens (or are counted at a lower rate) by ReqLLM's metadata.
2. **Thinking verbosity.** The tagged prompt section may elicit more
   `<thinking>` content. Worth spot-checking whether either run has
   disproportionately larger pre-envelope prose.
3. **Measurement artifact.** ReqLLM / OpenRouter may report output
   tokens differently for native tool_calls vs. assistant text;
   `:structured`'s tool_call payloads might not be fully accounted in
   the `output_tokens` field.

The third explanation is the most likely primary driver — native
tool_call payloads are often returned as structured fields that
providers under-count in billable output tokens. This would mean the
regression is partly a counting artifact, not 17% more real work.

### Decision

Per the gate in `docs/next-session-prompt.md`:
**"Tokens regress → investigate before migrating more agents. Most
likely culprit: throttled partial-parse firing too eagerly."**

Outcome: do **not** flip `default` agent to `:tagged` yet. Keep
`spreadsheet` on `:tagged` (it is shipping with acceptable performance,
completion parity confirmed). Before expanding the migration:

1. **Confirm or refute the counting-artifact hypothesis.** Compare
   per-turn prompt/response bodies side-by-side for one turn from each
   session; count actual characters emitted by the model vs. reported
   `output_tokens`. If `:structured` under-reports real payload,
   normalize the comparison.
2. **Measure partial-parse overhead properly** via an always-on
   telemetry recorder (supervision-tree embedded) — the 2% target
   remains unverified.
3. **Spot-check `:tagged` thinking verbosity** — compare the first 3
   assistant turns in each session for prose bloat that could be
   trimmed via prompt section wording.

Only after (1) is resolved should a default-agent flip be considered.

---

## Outcome (2026-04-05)

After the live eval, `:tagged` was removed from the codebase. The
workflow regression (skipped `add_rows` skeleton + single-turn batch
dispatch with no user-approval pause) was judged a harder problem than
the envelope-escape problem `:tagged` was originally designed to solve:
the LiveView UX pain that motivated Phase 1 can be addressed directly
by lenient-parsing structured-reasoner output for display, without
needing a second reasoner path.

Artifacts kept:

- `Rho.Parse.Lenient` — core lenient JSON parser + `parse_partial/1`
  for streaming prefixes.
- `[:rho, :parse, :lenient, :parse]` telemetry event.
- `prompt_sections/1` reasoner behaviour callback (generic across
  reasoners).
- `RhoWeb.ArgFormatter` — lenient-parses `*_json` / `*_raw` /
  `*_payload` / `arguments` tool-arg fields for the chat UI.
- `RhoWeb.StreamEnvelope` — detects in-flight JSON envelopes in
  streaming assistant text and surfaces a `{action, thinking}`
  preview card above the raw stream.

Artifacts removed:

- `Rho.Reasoner.Tagged{,.Coerce,.Dispatch,.PromptSection}`
- `test/rho/reasoner/tagged_*`, `test/rho/reasoner/tagged/**`
- `test/rho/reasoner/comparison_test.exs`
- `[:rho, :reasoner, :tagged, :slip_recovery]` telemetry
- `:tagged` shorthand in `Rho.Config.@reasoner_modules`

## Historical next-actions (superseded)

1. **Fix the workflow regression (blocking).** Inspect
   `Rho.Reasoner.Tagged` dispatch: does it execute multiple
   `<action>` envelopes per model response, or does the model truly
   emit a single tool call that happens to be `delegate_task`? Two
   hypotheses to test:
   - (dispatch-side) Tagged loop dispatches multiple actions per turn,
     bypassing the approval gate. Fix: enforce single-action-per-turn.
   - (prompt-side) The tagged prompt section underweights the "STOP
     and ask" instruction. Fix: strengthen the prompt section.
   Capture one failing `:tagged` session with full raw model response
   text preserved; identify whether the model emitted 1 or many
   actions in the turn that should have been `add_rows`.
2. **Investigate the token regression** (secondary). Diff a
   representative assistant turn between `tagged_eval_1` and
   `structured_eval_1`; confirm whether the 17% delta is envelope
   overhead vs. a native-tool_call token counting artifact.
3. **Embed always-on telemetry recorder** (supervision-tree child) so
   `[:rho, :parse, :lenient, :parse]` and
   `[:rho, :reasoner, :tagged, :slip_recovery]` events from the
   Phoenix BEAM land in
   `_rho/sessions/<session_id>/reasoner_telemetry.jsonl` without a
   separate `mix rho.reasoner_report --attach` process.
4. **Hold on default-agent flip** until (1) and (2) are resolved.
5. Deferred Phase 1 items still open: concurrency/load tests (1.27),
   tape-replay compatibility (1.28).
