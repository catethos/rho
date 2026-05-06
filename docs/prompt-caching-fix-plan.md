# Prompt-caching fix plan

## Context

The spreadsheet agent's effective prompt embeds a **volatile** "Active data
tables" block inside the same system-prompt string as the stable workflow
rules. Result: every change to row counts, active-tab marker, or selected
rows invalidates the entire system-prompt cache between user turns. The
`TypedStructured` turn strategy makes this strictly worse because it
flattens everything into a single string and routes through a BAML →
OpenRouter (`openai-generic`) path that drops Anthropic-style
`cache_control` metadata on the floor.

This plan scopes the smallest set of changes that recover meaningful
prompt-cache hit rates without rearchitecting the BAML transport.

## What's actually happening (file-level)

- `Rho.Runner.build_system_prompt/4` (`apps/rho/lib/rho/runner.ex:299-328`)
  collects `Rho.PromptSection`s from base prompt, plugins, strategy, and
  `@conciseness_section`, splits prelude vs. postlude, and joins everything
  with `\n\n` into a single string stored on `Runtime.system_prompt`.
- `Rho.Runner.build_initial_context/2` (`runner.ex:349-363`) wraps that
  whole string in **one** `ReqLLM.Message.ContentPart.text(..., %{cache_control:
  %{type: "ephemeral"}})`. The volatile section therefore sits **inside**
  the cached part — any change busts the cache.
- `Rho.Stdlib.Plugins.DataTable.prompt_sections/2`
  (`apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex:42-67`) emits the
  `:data_table_index` section, whose body changes every time a row is
  added/removed, the active panel switches, or selections change.
- `Rho.TurnStrategy.TypedStructured.run/2`
  (`apps/rho/lib/rho/turn_strategy/typed_structured.ex:38-66`) calls
  `serialize_messages/1` which `Enum.map_join`s every message into a flat
  string and hands it to `BamlElixir.Client.sync_stream("AgentTurn",
  %{messages: messages_text}, ...)`. The BAML function template
  (`apps/rho/priv/baml_src/dynamic/action.baml:165-172`) is just
  `{{ messages }}\n\n{{ ctx.output_format }}`. ReqLLM's `cache_control`
  metadata is gone before BAML sees the input.
- `RhoBaml.SchemaWriter.write!`
  (`apps/rho_baml/lib/rho_baml/schema_writer.ex:46-56`) rewrites
  `action.baml` (and `client.baml`) on every turn whether contents
  changed or not.
- Within a single `Runner.run` invocation, `system_prompt` is built once
  (`runner.ex:185`) and reused across inner steps, so multi-step runs
  inside one user turn do already share a stable system prompt — the
  problem is **between** user turns, when `prompt_sections` is recollected
  and the volatile block changes.

## Goals & non-goals

**Goals**
- Stable system-prompt content can be cached across user turns even when
  data-table state changes.
- TypedStructured benefits from upstream **automatic** prefix caching
  (OpenAI / Anthropic-via-OpenRouter) without changing the BAML
  transport.
- No regressions for `Direct` strategy.
- No structural change to `Rho.PluginRegistry` or to plugin authors
  besides one optional flag.

**Non-goals (this round)**
- Replacing BAML as the TypedStructured transport.
- Adding multi-breakpoint caching to the *conversation tape* (separate
  follow-up).
- Per-tool deferred-loading caching impact (separate concern).

## Plan

### Layer A — core: split stable vs. volatile prompt sections

1. **Add `:volatile` to `Rho.PromptSection`.**
   - `apps/rho/lib/rho/prompt_section.ex` — add `:volatile` (boolean,
     default `false`) to the struct, the typespec, and `new/1`.
   - `from_string/1` defaults to `volatile: false`.

2. **Teach `build_system_prompt/4` to return a 2-tuple.**
   - `apps/rho/lib/rho/runner.ex:299-328` — change the return to
     `{stable_text, volatile_text}`.
   - Render order stays the same (prelude / strategy / postlude). Within
     each rendered group, partition sections by `:volatile`. Volatile
     sections always render *after* stable ones in the output.
   - Preserve current behavior when no section is marked volatile:
     `volatile_text` is `""` and the assembly downstream behaves
     identically to today.

3. **Carry both strings on `Runtime`.**
   - Replace `system_prompt :: String.t()` with
     `system_prompt_stable :: String.t()` and `system_prompt_volatile ::
     String.t()` (or one `system_prompt :: {stable, volatile}` — pick
     whichever feels less invasive given the existing call sites in
     `runner.ex` and any test fixtures).
   - Update `build_runtime/1` and the legacy `build_runtime/3`
     (`runner.ex:148-237`) accordingly.

4. **Mark the DataTable index section volatile.**
   - `apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex:54-62` — add
     `volatile: true` to the `%Rho.PromptSection{}` it returns.
   - Audit other plugin `prompt_sections` callbacks for anything else
     that's clearly volatile (e.g. anything reading session state mid-run);
     leave them stable for now if uncertain — `volatile: true` is the
     opt-in, default behavior preserves cache-hostility but matches today.

5. **Tests.**
   - Unit-test `build_system_prompt/4` with a mix of stable and volatile
     sections; assert ordering and tuple shape.
   - Snapshot a known prompt (existing tests, if any) to confirm stable
     output is byte-identical to the old single-string output when no
     section is volatile.

### Layer B — `Direct` strategy: two-part system message

Apply the split where ReqLLM does honor `cache_control`.

1. **`build_initial_context/2` (`runner.ex:349-363`).** Replace the single
   `ContentPart.text` with two parts inside one `ReqLLM.Context.system/1`:
   - Part 1: `system_prompt_stable` with `cache_control: %{type:
     "ephemeral"}`.
   - Part 2: `system_prompt_volatile` (only if non-empty) with **no**
     `cache_control`.
   - When `system_prompt_volatile == ""`, fall back to the single-part
     form so we don't pay for an empty content part.

2. **`build_lite_context/2` (`runner.ex:427-436`).** Same treatment — the
   lite loop runs the same path through ReqLLM.

3. **Sanity check: Anthropic supports up to 4 breakpoints**, and a part
   without `cache_control` following one with it does not invalidate the
   earlier cache. The volatile part is appended *after* the stable
   ephemeral breakpoint, so the stable prefix remains addressable as a
   cache prefix on subsequent calls.

4. **Tests.**
   - Assert the system message has two parts when both stable and
     volatile text exist, and the first part carries `cache_control`.
   - Assert the system message has one part when volatile is empty and
     that part still carries `cache_control` (parity with today).

### Layer C — `TypedStructured`: reorder for upstream automatic caching

BAML flattens to one user-message string, and the dynamic client is
`openai-generic` against OpenRouter — so explicit Anthropic
`cache_control` is not the lever. The lever is **upstream automatic
prefix caching** (OpenAI's automatic prompt caching, plus Anthropic via
OpenRouter when supported), which requires a long *byte-identical
prefix*. Move the volatile content out of the prefix.

1. **Update `serialize_messages/1` (`typed_structured.ex:262-281`).**
   - Detect the system message (`role: :system` or stringified
     `"system"`) and split its content into stable vs. volatile, using
     the same split contract Layer A produces.
     - Practical implementation: have the runner stash the volatile text
       on `runtime.system_prompt_volatile`, and have TypedStructured
       *bypass* the system-message text in the `messages` list — instead
       it serializes only the stable system text plus the rest of the
       conversation, then appends the volatile block at the end.
   - Resulting `messages_text` shape:
     ```
     System: <stable system prompt>

     User: ...
     Assistant: ...
     User: ...

     System: ## Active data tables
     ...volatile body...
     ```
     followed by BAML's `{{ ctx.output_format }}`. The stable preamble
     plus most of the conversation stays byte-identical between
     consecutive user turns; only the volatile tail and the new user
     message change.

2. **Do not change the BAML function signature.** A nicer fix would be a
   second BAML arg `ui_state: string` with template
   `{{ messages }}\n\n{{ ui_state }}\n\n{{ ctx.output_format }}`. Defer
   that — it's a strict superset and can land later without touching
   the caching logic.

3. **`build_think_step/1` and `build_tool_step/3` (`typed_structured.ex:101-131`)
   already encode messages without touching the system prompt, so they
   are unaffected.**

4. **Tests.**
   - Given a runtime with non-empty `system_prompt_volatile`, assert
     `serialize_messages/1` (or whatever helper it factors into):
     - Starts with stable system text.
     - Contains conversation messages in order, unmodified.
     - Ends with the volatile block.
   - With empty volatile text, output is byte-identical to the current
     implementation (regression guard).

### Layer D — minor cleanups

These do not change LLM behavior but reduce noise around the same code paths.

1. **Skip `SchemaWriter.write!` when contents are unchanged.**
   - `apps/rho_baml/lib/rho_baml/schema_writer.ex:46-56` — hash the
     generated `action.baml` (and `client.baml`) bytes; only write when
     the file is missing or content differs. Cuts disk I/O on every
     turn.
   - This must remain correct under concurrent runs in the same VM —
     the file path is shared. Either keep the current
     unconditional-overwrite behavior under a lock, or version the file
     by hash. Simpler: read existing file, compare bytes, write iff
     different. BAML re-reads the file on every `sync_stream`, so a
     no-op write is fine — this is purely an FS-noise reduction.

2. **Add a second cache breakpoint on the conversation tape (Direct only).**
   - In `build_initial_context/2`, after building `[system_msg | tail]`,
     mark a `cache_control: ephemeral` on the *last* assistant/tool
     message in `tail` (i.e. just before the most recent user message).
     This lets multi-turn conversations cache the entire prefix up to
     the last assistant turn.
   - Anthropic allows 4 breakpoints total; we'd be using 2 (stable
     system, conversation prefix). Plenty of headroom.
   - Skip if `tail` is empty or has fewer than 2 entries.
   - Optional: skip if the run is `lite: true` (no tape, no point).

3. **Mark `:volatile` on any other prompt sections that are obviously
   live state.** Quick audit pass — leave unsure ones stable. Candidates
   to inspect:
   - `Rho.Stdlib.Plugins.MultiAgent` (delegate roster — usually stable
     within a run, but check).
   - `Rho.Stdlib.Plugins.LiveRender` (if it injects view state).
   - `Rho.Stdlib.Skill.Plugin` (loaded skills — stable within a run if
     skills don't load mid-run; possibly volatile if they do).

## Out of scope, flagged for later

- **TypedStructured native caching.** Real `cache_control` propagation
  through TypedStructured requires either (a) BAML→Anthropic-direct with
  verified `cache_control` pass-through, or (b) replacing BAML transport
  with ReqLLM and using BAML only for schema-class generation. Layer C-1
  gets us most of the benefit via automatic upstream caching; this
  remaining work is a separate design pass.
- **Per-turn dynamic tool visibility.** Skills that load tools mid-run
  change the `{{ ctx.output_format }}` block, which sits at the *end* of
  the prompt — fine for prefix caching but worth measuring.
- **Conversation-tape volatility.** Long-running tapes accumulate text;
  when compaction kicks in, the prefix changes mid-run. Compaction
  events are already rare; just a note.

## Acceptance criteria

- `Direct` strategy: a multi-turn session where DataTable state changes
  between turns shows a cache hit on the stable system prefix on the
  second and subsequent turns (verifiable via Anthropic usage telemetry
  if available, or by asserting the constructed message structure has
  two parts with the expected `cache_control` placement).
- `TypedStructured` strategy: in the serialized prompt sent to BAML,
  the byte sequence up to the start of the conversation tail is
  identical between two consecutive turns when only DataTable state
  has changed (regression test on `serialize_messages/1`).
- No change to existing `.rho.exs` configs is required.
- All existing tests pass; new tests cover the Layer A, B, C splits.

## Suggested commit slicing

1. **`prompt-section: add :volatile flag and split renderer`** — Layer A
   only, no behavior change yet (every call site still concatenates
   stable + volatile and uses it as before).
2. **`runner(direct): emit two-part system message with cache_control on
   stable`** — Layer B, plus mark DataTable section volatile.
3. **`turn_strategy(typed_structured): hoist volatile prompt section to
   end of serialized messages`** — Layer C-1.
4. **`schema_writer: skip rewrite when contents unchanged`** — Layer D-1.
5. **`runner(direct): cache_control on conversation prefix`** — Layer
   D-2.

Each commit is independently revertable.
