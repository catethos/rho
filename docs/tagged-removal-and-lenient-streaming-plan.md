# Remove `:tagged` reasoner + repurpose `Rho.Parse.Lenient` for streaming UX

**Status:** All three steps complete (2026-04-05).
**Context:** Phase 1 live eval found two `:tagged` regressions (skipped
skeleton phase, +17% tokens). Pivot: delete `:tagged`, keep
`Rho.Parse.Lenient`, use it to prettify `:structured` streaming output.
See `docs/reasoner-baml-results.md` for the eval findings.

> **Vocabulary note (post-refactor).** "Reasoner" in this document =
> `Rho.TurnStrategy` in current code. `:structured` resolves to
> `Rho.TurnStrategy.Structured`. See `CLAUDE.md` §"Migration from
> Mount/Memory/Reasoner".

## Scope

### Remove (tagged reasoner)

Files to delete:

- `lib/rho/reasoner/tagged.ex`
- `lib/rho/reasoner/tagged/coerce.ex`
- `lib/rho/reasoner/tagged/dispatch.ex`
- `lib/rho/reasoner/tagged/prompt_section.ex`
- `test/rho/reasoner/tagged_test.exs`
- `test/rho/reasoner/tagged_corpus_test.exs`
- `test/rho/reasoner/tagged/coerce_test.exs`
- `test/rho/reasoner/tagged/dispatch_test.exs`
- `test/rho/reasoner/tagged/execution_test.exs`
- `test/rho/reasoner/tagged/property_test.exs`
- `test/rho/reasoner/tagged/streaming_test.exs`

Files to edit:

- `lib/rho/config.ex` — drop `:tagged` from `@reasoner_modules`.
- `.rho.exs` — remove the `reasoner: :tagged` override on `spreadsheet`
  (falls back to `:structured`). Delete the related comment.
- `test/rho/reasoner/comparison_test.exs` — decide: drop `:tagged`
  comparisons, OR re-purpose as a corpus regression test for
  `Rho.Parse.Lenient` only. Probably drop the `:tagged` arm.
- `lib/mix/tasks/rho.reasoner_report.ex` — telemetry attach handler for
  `[:rho, :reasoner, :tagged, :slip_recovery]` becomes dead code; remove
  that branch. Keep `[:rho, :parse, :lenient, :parse]`.
- `test/support/reasoner_harness.ex` — drop tagged-mode harness option
  if present.

Keep:

- `lib/rho/parse/lenient.ex` + `test/rho/parse/` — core artifact we're
  repurposing.
- `test/rho/reasoner/structured_corpus_test.exs` — baseline regression
  protection for `:structured`.
- `test/rho/reasoner/structured_integration_test.exs` — `:structured`
  integration coverage.
- `[:rho, :parse, :lenient, :parse]` telemetry event.
- `prompt_sections/1` reasoner behaviour callback — stays generic.

Docs to update:

- `docs/reasoner-baml-results.md` — add a "Phase 1 Outcome" section:
  Tagged didn't survive live eval; pivoting Lenient to streaming UX.
- `docs/reasoner-baml-plan.md` — supersede or annotate with pivot
  notice at the top.
- `docs/next-session-prompt.md` — delete (superseded by this file).
- `docs/reasoner-baml-critique.md` — leave as-is (historical record)
  unless stale.

### Add (streaming UX via `Rho.Parse.Lenient`)

**A. Streaming tool-args renderer.** When `:structured` streams a
tool_call with a partial JSON argument payload (typical culprit:
`rows_json`, `changes_json`, `levels_json`), lenient-parse the
in-flight arg value on each streaming delta and render partial
structured content in the chatbox. Example: while
`add_rows(rows_json: "[{\"name\":\"Ta...")` streams in, show
"Adding row 1: Ta..." instead of the raw escaped string.

**B. Streaming envelope-fallback renderer.** When assistant text from
`:structured` begins with `{` or ` ```json {` (the model fell back to
emitting a JSON envelope in text instead of using native tool_calls),
lenient-parse on each delta and render an action/args preview card
rather than raw streaming JSON text.

## Plan

### Step 1 — Delete `:tagged` reasoner (self-contained refactor) ✅

Deleted 11 tagged files + `comparison_test.exs`. Dropped `:tagged`
from `Rho.Config.@reasoner_modules`. Flipped spreadsheet agent back
to `:structured`. Rewrote `structured_corpus_test.exs` as a single-
reasoner baseline. Removed `:slip_recovery` handler from
`rho.reasoner_report`. Cleaned `test/support/reasoner_harness.ex`.
`mix test` green (336 tests).

### Step 2 — Streaming tool-args renderer (feature A) ✅

Added `RhoWeb.ArgFormatter.extract_inner_json/1` — walks a
tool-args map, lenient-parses fields matching `*_json` / `*_raw` /
`*_payload` / `arguments`, returns `{labelled_parts, remaining}`.
`chat_components.ex:format_tool_args/2` calls it so the chat UI
renders decoded rows/payloads instead of raw escaped strings. 13
unit tests in `test/rho_web/arg_formatter_test.exs`.

### Step 2 — Streaming tool-args renderer (feature A)

1. Identify where streaming tool_call deltas land:
   - `lib/rho/reasoner/structured.ex` — find where per-chunk tool args
     accumulate and what telemetry/events fire.
   - `lib/rho_web/live/spreadsheet_live.ex` — find where tool_call UI
     renders during streaming (likely via Observatory event stream).
   - `lib/rho_web/components/chat_components.ex` — tool-call component
     rendering.
2. Add a streaming-aware argument formatter, e.g.
   `Rho.Tools.ArgFormatter` or `Rho.Reasoner.Structured.StreamingArgs`.
   Takes partial raw JSON string → lenient-parse → pretty render.
3. Special-case `_json`-suffix args: auto-lenient-parse their inner
   JSON string too, so streaming `rows_json: "[{\"name\": \"Ta..."`
   shows as `rows: [{name: "Ta..."}, ...]`.
4. Wire the formatter into the chat tool-call component. Throttle
   partial-parse calls to ~100ms cadence per tool call to avoid
   render thrashing.
5. Tests:
   - Unit test: partial `rows_json` payloads at various truncation
     points produce sensible partial output.
   - LiveView test: streaming a tool_call chunk-by-chunk updates the
     visible DOM incrementally.
6. Commit: "Lenient-parse streaming tool_call args for chat UI"

### Step 3 — Streaming envelope-fallback renderer (feature B) ✅

Added `RhoWeb.StreamEnvelope.analyze/1` — lenient-parse-partial on
accumulated streaming buffer; returns `{:envelope, %{action,
action_input, thinking}}` or `:no_envelope`. Falls back to regex
scraping when the auto-closer can't produce valid JSON (deeply-
nested partial envelopes). `SessionProjection.project_text_delta/2`
runs it on every chunk and stores the result in
`inflight[agent_id].envelope`. `chat_feed/1` template renders an
`envelope_preview/1` chip above the streaming body when present.
16 unit tests in `test/rho_web/stream_envelope_test.exs`. Also
upgraded `ChatComponents.parse_thinking/1` to use
`Rho.Parse.Lenient.parse/1` (handles fenced JSON in post-flush
thinking messages).

### Step 3 — Streaming envelope-fallback renderer (feature B)

1. Identify the point in `:structured` where the assistant text chunk
   is pushed to the LiveView chat bubble (probably in chat_components
   or a message formatter).
2. Detect envelope candidacy on first non-whitespace char (`{` or
   fenced ```json) — once detected, lock that message into
   "envelope rendering" mode for the rest of the stream.
3. Lenient-parse the accumulated text each delta; extract `action` +
   `action_input` (or `tool` + `arguments` variants) and render a
   preview card. If parse fails or loses envelope shape mid-stream,
   fall back to raw text rendering.
4. Tests:
   - Unit test: streaming a JSON envelope chunk-by-chunk yields
     action name on first curly, action args when available.
   - Ensure non-envelope assistant text is untouched.
5. Commit: "Lenient-parse streaming assistant-text envelopes for chat UI"

### Step 4 — Docs + cleanup

1. Update `docs/reasoner-baml-results.md` with a Phase 1 outcome
   section + link to this plan.
2. Update `docs/reasoner-baml-plan.md` top with pivot notice.
3. Delete `docs/next-session-prompt.md`.
4. Move this plan to `docs/lenient-streaming-ux.md` once Step 1+2+3
   ship; delete its `Plan` section, retain the design notes.
5. Commit: "Docs: record tagged-reasoner removal + lenient streaming pivot"

## Verification

After each step:
- `mix compile --warnings-as-errors`
- `mix test`

After Step 2 + 3, smoke-test manually:
- Run the spreadsheet agent in `/spreadsheet/smoke_test_1`.
- Submit a prompt that will trigger `add_rows` with a large
  `rows_json`.
- Observe streaming tool-call UI in the chatbox.

## Open questions (resolve as we go)

- Should the streaming formatter handle non-`_json`-suffix args too
  (generic `"arguments":"...JSON..."` strings)? Likely yes —
  the root cause is "models escape JSON in strings," not the
  naming convention.
- Does `ReqLLM` stream tool_call args as incremental `delta` strings
  or as whole replacements? Affects parser input strategy.
- Where is the current chat/tool_call streaming latency bottleneck —
  would a 100ms throttle on lenient-parse be noticeable?
