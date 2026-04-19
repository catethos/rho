# Schema-Aligned Parsing for Rho — Revised Plan (v3)

> Supersedes previous plan. Incorporates findings from `simplify_baml` (Rust),
> Tao (Rust agent), GenBAML (Elixir DSL), the BoundaryML blog post, and an
> oracle review focused on integration risk, safety guardrails, and Elixir
> idioms.

## Executive Summary

Add schema-aligned parsing (SAP) to Rho's agent loop. SAP uses tool
parameter schemas to guide error correction on LLM output — coercing
wrong types, unwrapping wrapper objects, normalizing enum variants, and
handling missing/extra fields.

The work is a **~300-line pure Elixir port** of the coercion layer from
`simplify_baml/src/parser.rs`, integrated into `Rho.ToolArgs` as a
unified `cast → coerce → validate` pipeline. It benefits all tool
execution paths: Direct, Structured, DSL, Worker, and LiteWorker.

The end goal is a **strict typed protocol** for all actions via
`ActionSchema` and a new `:typed_structured` strategy — every possible
LLM response maps to exactly one variant of a closed discriminated union.

---

## Why — The Evidence

### Benchmark: SAP outperforms everything else

Berkeley Function Calling Leaderboard (n=1000):

| Model             | Function Calling | Python AST | SAP       |
|-------------------|-----------------|------------|-----------|
| Claude-3-Haiku    | 57.3%           | 82.6%      | **91.7%** |
| GPT-4o-mini       | 19.8%           | 51.8%      | **92.4%** |
| GPT-3.5-turbo     | 87.5%           | 75.8%      | **92.0%** |
| GPT-4o            | 87.4%           | 82.1%      | **93.0%** |
| Claude-3.5-Sonnet | 78.1%           | 93.8%      | **94.4%** |

Source: https://boundaryml.com/blog/schema-aligned-parsing

SAP beats function calling (Direct strategy) on every model. On Claude
Haiku (used by Rho's spreadsheet agent), SAP is 60% more reliable than
native tool_use. On GPT-4o-mini, it's 4.7x more reliable.

### Rho's own experience confirms this

From `docs/improvement-loop-round1.md` (2026-03-25):

> Structured reasoner (`reasoner: :structured`) uses `stream_text` without
> native tool_use — tools described only in prompt. LLM frequently ignored
> JSON format and answered in plain text.
> Fix: Switched to `reasoner: :direct`.

The structured strategy was demoted because it's unreliable. But the
spreadsheet agent (`.rho.exs:56`) still uses `:structured` for its streaming
visibility and thinking trace. SAP makes Structured competitive again.

### The core insight (Postel's Law)

> "Be conservative in what you do, be liberal in what you accept."

SAP doesn't constrain the model during generation — it corrects after the
fact using schema knowledge. This makes it model-agnostic, provider-agnostic,
and complementary to other approaches (stack with `response_format` or
function calling for even better results).

---

## What — The Gap in Rho Today

### What Rho has (Layer 1: syntax repair)

`Rho.StructuredOutput` (537 lines) handles JSON syntax errors:
- Unicode quote normalization
- Control character escaping
- Trailing comma stripping
- Markdown fence extraction
- Merged object detection
- Brace-matching scan
- Single-quote conversion
- Partial JSON auto-closing (streaming)

This is solid. Keep it as-is.

### What Rho is missing (Layer 2: schema-guided coercion)

When `StructuredOutput` produces valid JSON, Rho treats it as an opaque
`Map<String, any>`. It doesn't know that `"30"` should be `30`, that
`"january"` should be `"January"`, that `"hello"` should be `["hello"]`,
or that `{"value": "text"}` should be `"text"`.

The coercion layer from `simplify_baml/src/parser.rs` (lines 227-561)
fills this gap. It's a recursive function that walks the JSON value and
coerces each node to match the expected type from the schema.

### All tool execution paths (5 call sites)

Coercion must be integrated at **all** call sites, not just 2:

| Call site | File | Current behavior |
|-----------|------|------------------|
| **Direct strategy** | `turn_strategy/direct.ex:140-143` | `ToolArgs.cast` only |
| **Structured strategy** | `turn_strategy/structured.ex:255-256` | `ToolArgs.cast` only |
| **DSL-generated tools** | `tool/dsl.ex:87-96` | `ToolArgs.cast` + `validate_required` |
| **Worker (direct cmd)** | `agent/worker.ex:1017-1018` | `ToolArgs.cast` only |
| **LiteWorker** | `agent/lite_worker.ex:407` | `ToolArgs.cast` only |

The safest way to cover all paths: **put coercion inside `Rho.ToolArgs`**
as a unified pipeline, so every caller gets it automatically.

### What we learned from Tao and BAML

**Tao** (`/Users/catethos/workspace/tao`) — Rust agent using `simplify_baml`:
- All LLM responses are tool calls. Even "speak to user" is
  `FinalResponse { message: String }`. No raw text case.
- `Think { thought: String }` is a first-class tool for visible reasoning.
- The `Tool` enum is a tagged/discriminated union (`#[baml(tag = "tool")]`).
- The agent loop is: `parse → match variant → execute → loop`. Trivially
  simple because the action space is total.

**GenBAML** (`/Users/catethos/workspace/ds-agents/.../genbaml`) — Elixir DSL:
- Compile-time schema definitions → BAML file generation.
- `BamlElixir.Native.call/6` wraps BAML's Rust runtime via NIF.
- Requires `.baml` files on disk — cannot pass schemas programmatically.
- Good for standalone structured extraction, but the file-on-disk requirement
  and separate LLM communication layer make it a poor fit as the inner loop
  of Rho's agent runtime.

**simplify_baml** (`/Users/catethos/workspace/simplify_baml/src/`) — the parser:
- `ir.rs`: Type system — `FieldType` enum (String, Int, Float, Bool, Class,
  Enum, TaggedEnum, List, Map, Union), `Class`, `Field`, `TaggedEnum`,
  `TaggedVariant`.
- `parser.rs`: 3-phase pipeline — extract JSON → parse → coerce to type.
  The coercion functions are the key: `coerce_string`, `coerce_int`,
  `coerce_float`, `coerce_bool`, `coerce_enum`, `coerce_class`,
  `coerce_list`, `coerce_map`, `coerce_union`, `coerce_tagged_enum`.
- `schema.rs`: Human-readable schema formatter for prompt injection. BAML
  format: `{name: string, age?: int, tags: string[]}` with enum definitions
  listed above.
- Object unwrapping: when expecting a primitive but receiving an object, tries
  field names `value`, `Value`, `string`, `String`, `text`, `Text`, `result`,
  `Result`, then falls back to single-field unwrap.

**Key conclusion**: We don't need BAML as a dependency. The coercion logic is
~335 lines of Rust that maps naturally to ~150 lines of Elixir pattern matching.
Rho's `StructuredOutput` already covers the JSON extraction phase. The only
missing piece is the schema-guided coercion phase.

---

## How — Design

### Architecture overview

```
apps/rho/lib/rho/
├── schema_coerce.ex              # Pure recursive coercion engine (~150 lines)
├── tool_args.ex                  # Unified pipeline: cast → coerce → validate
├── action_schema.ex              # Tagged union from tool_defs (~120 lines)
│                                 # includes prompt formatting + collision detection
├── turn_strategy/
│   ├── structured.ex             # UNCHANGED until typed_structured is validated
│   └── typed_structured.ex       # New strategy using ActionSchema
└── structured_output.ex          # UNCHANGED
```

### Module boundaries

- **`Rho.SchemaCoerce`** — pure recursive coercion engine. No dependencies
  on ToolArgs, ActionSchema, or any Rho module. Input: `(value, type_spec)`.
  Output: `{:ok, coerced, repairs}` or `{:error, reason}`. Reusable for
  both tool args and structured extraction.

- **`Rho.ToolArgs`** — public orchestration API. Calls `cast/2`, then
  `SchemaCoerce.coerce_fields/3`, then `validate_required/2`. All 5 call
  sites use this single entry point.

- **`Rho.ActionSchema`** — tagged union builder + parse/dispatch for the
  typed structured strategy only. Handles collision detection, built-in
  variant reservation, and prompt rendering.

### Module 1: `Rho.SchemaCoerce`

Port of `simplify_baml/src/parser.rs` lines 227-561.

**Source reference**: `/Users/catethos/workspace/simplify_baml/src/parser.rs`

#### Safety-adapted coercion rules

The original simplify_baml rules are designed for **extraction tolerance**.
For **tool invocation safety**, we apply stricter guardrails:

```
coerce(value, expected_type, mode) → {:ok, coerced, repairs} | {:error, reason}
```

**Mode `:tool_call`** (default for ToolArgs pipeline):

| Expected type          | LLM output               | Coercion                          | Source (parser.rs) |
|------------------------|---------------------------|-----------------------------------|--------------------|
| `:string`              | `42`                      | `"42"`                            | line 256           |
| `:string`              | `true`                    | `"true"`                          | line 257           |
| `:string`              | `nil`                     | ❌ `{:error, :nil_for_required}` if required, passthrough if optional | **DIFFERS from simplify_baml** |
| `:string`              | `%{"value" => "text"}`    | `"text"` (unwrap known keys only) | lines 259-273      |
| `:string`              | `%{"x" => "text"}`        | ❌ no single-field unwrap in tool mode | **DIFFERS** |
| `:integer`             | `"30"`                    | `30`                              | lines 296-299      |
| `:integer`             | `3.0`                     | `3` (if no fractional part)       | lines 284-291      |
| `:integer`             | `%{"value" => 42}`        | `42` (unwrap known keys only)     | lines 301-315      |
| `:float`               | `"3.14"`                  | `3.14`                            | lines 330-333      |
| `:float`               | `42` (integer)            | `42.0`                            | implicit           |
| `:boolean`             | `"true"/"yes"/"1"`        | `true`                            | lines 358-367      |
| `:boolean`             | `"false"/"no"/"0"`        | `false`                           | lines 358-367      |
| `:boolean`             | `1` / `0`                 | `true` / `false`                  | lines 368-372      |
| `{:in, variants}`      | `"january"`               | `"January"` (case-insensitive)    | lines 395-421      |
| `{:list, inner}`       | scalar value              | `[value]` (scalar-to-list wrap)   | lines 506-511      |
| `{:list, inner}`       | `[items]`                 | recursive coerce each item        | lines 500-505      |
| `{:map, _}`            | `%{k => v}`               | recursive coerce values           | lines 514-528      |
| tagged enum            | `%{"tool" => "Bash", ...}` | match variant, coerce fields     | lines 423-466      |

**Guardrails (differ from simplify_baml):**

1. **No `nil → ""` for required fields.** `nil` on a required string returns
   `{:error, {:missing_required, field}}`, not `""`. This prevents bypassing
   `validate_required/2` with empty strings that silently flow into tool
   callbacks expecting real values.

2. **No arbitrary `:atom` coercion.** LLM input is untrusted — converting
   arbitrary strings to atoms is a memory leak / DoS vector on the BEAM.
   Atom coercion is whitelist-only: only convert when the `{:in, variants}`
   list contains atoms.

3. **Strict unwrap for tool mode.** Only unwrap known wrapper keys
   (`value`, `text`, `result` and their capitalized forms). Do NOT do
   arbitrary single-field object unwrap in tool mode — it's too liberal for
   tool calls where the field name might be semantically important (paths,
   IDs, commands).

4. **All coercions produce a repair log.** Every coercion records
   `{field, from_type, to_type, original_value}` so we can audit what
   changed, emit telemetry, and debug chronic offenders.

**Mode `:extraction`** (for future use in structured extraction):
Mirrors the original simplify_baml behavior exactly, including `nil → ""`,
single-field unwrap, and liberal atom coercion. Not used in Phase 1.

#### Object unwrapping (known keys only in tool mode)

When expecting a primitive type but receiving an object, try these field
names in order (from parser.rs line 262):

```elixir
@wrapper_keys ~w(value Value text Text result Result)
```

In `:extraction` mode, also try `string`, `String` and fall back to
single-field unwrap. In `:tool_call` mode, stop at the known keys list.

#### API

```elixir
# Coerce a single value to match expected type
SchemaCoerce.coerce(value, :integer)
→ {:ok, 30, [%{from: :string, to: :integer, original: "30"}]}

SchemaCoerce.coerce(value, :integer)
→ {:error, {:cannot_coerce, :map, :integer}}

# Coerce all fields in a map against a parameter_schema keyword list
SchemaCoerce.coerce_fields(args_map, parameter_schema, mode: :tool_call)
→ {:ok, coerced_map, repairs}

# mode defaults to :tool_call
```

### Module 1b: `Rho.ToolArgs` — Unified pipeline

Extend the existing `Rho.ToolArgs` with a `prepare/2` function that
orchestrates the full pipeline. All 5 call sites switch to this.

```elixir
@doc """
Full arg preparation pipeline: cast → coerce → validate.

Returns `{:ok, prepared_args, repairs}` or `{:error, reason}`.
Repairs is a list of coercion actions taken (empty if args were
already correctly typed).
"""
@spec prepare(map(), keyword()) :: {:ok, map(), list()} | {:error, term()}
def prepare(args, parameter_schema) when is_list(parameter_schema) do
  cast = cast(args, parameter_schema)

  with {:ok, coerced, repairs} <-
         Rho.SchemaCoerce.coerce_fields(cast, parameter_schema, mode: :tool_call),
       :ok <- validate_required(coerced, parameter_schema) do
    if repairs != [] do
      :telemetry.execute(
        [:rho, :tool, :args_coerced],
        %{repair_count: length(repairs)},
        %{repairs: repairs}
      )
    end

    {:ok, coerced, repairs}
  end
end

def prepare(args, _non_list_schema), do: {:ok, args, []}
```

**Migration for call sites** — each switches from:
```elixir
cast_args = Rho.ToolArgs.cast(args, schema)
tool_def.execute.(cast_args, ctx)
```
to:
```elixir
case Rho.ToolArgs.prepare(args, schema) do
  {:ok, prepared_args, _repairs} ->
    tool_def.execute.(prepared_args, ctx)
  {:error, reason} ->
    {:error, "Arg preparation failed: #{inspect(reason)}"}
end
```

This is more than "2 lines per strategy" — it's a result-tuple pipeline
change at 5 call sites plus tests, but the pattern is mechanical.

#### Auditability: raw vs prepared args

The Structured strategy currently records `new_args` (raw) in
`build_tool_step_from_result` (line 523-535), not `cast_args`. After SAP,
we must record **both** when they differ:

```elixir
# In build_tool_step_from_result, when repairs is non-empty:
structured_calls: [{name, Jason.encode!(prepared_args), raw_args: args}]
```

This preserves tape/UI fidelity: the user sees what the LLM said, but the
tool got the corrected values. Telemetry on `[:rho, :tool, :args_coerced]`
tracks repair frequency per tool/field for monitoring.

### Module 2: `Rho.ActionSchema`

Builds a tagged union from tool_defs and handles the full parse+dispatch
pipeline for the typed structured strategy.

**Inspired by**: Tao's `Tool` enum (`/Users/catethos/workspace/tao/crates/tao-core/src/tools.rs`),
simplify_baml's `TaggedEnum` (`/Users/catethos/workspace/simplify_baml/src/ir.rs` lines 110-124).

#### The action type

At agent boot, the tool set is fixed. ActionSchema converts tool_defs into
a closed discriminated union:

```
Action = respond(message: string)
       | think(thought: string)
       | bash(cmd: string)
       | fs_read(path: string, offset?: integer, limit?: integer)
       | ... one per registered tool
```

Every possible LLM response maps to exactly one variant. There is no
"raw text" case, no "code block fallback" case.

#### Built-in variants and collision detection

`respond` and `think` are **reserved** built-in variants. ActionSchema
must detect collisions at build time:

```elixir
def build(tool_defs) do
  reserved = MapSet.new(~w(respond think))
  tool_names = Enum.map(tool_defs, & &1.tool.name)

  # Fail fast on reserved name collisions
  for name <- tool_names, name in reserved do
    raise ArgumentError,
      "Tool name #{inspect(name)} collides with built-in action. " <>
      "Rename the tool or use a prefix."
  end

  # Fail fast on duplicate tool names
  dupes = tool_names -- Enum.uniq(tool_names)
  if dupes != [] do
    raise ArgumentError,
      "Duplicate tool names: #{inspect(Enum.uniq(dupes))}. " <>
      "Each tool must have a unique name."
  end

  %ActionSchema{
    variants: build_variants(tool_defs),
    tag_key: "tool"
  }
end
```

#### Format and parsing

Prompt format — flat JSON with `"tool"` as discriminant:

```json
{"tool": "bash", "cmd": "ls -la"}
```

`think` as an **optional side-channel field** on any action (not a
separate action that costs a turn):

```json
{"tool": "bash", "cmd": "ls -la", "thinking": "Let me check the directory"}
```

For standalone thinking (no tool call), use the think variant:

```json
{"tool": "think", "thought": "I need to reconsider my approach..."}
```

Terminal action:

```json
{"tool": "respond", "message": "Here is your answer..."}
```

#### Parse pipeline

```
Raw text
  → StructuredOutput.parse           # Layer 1: syntax repair (existing)
  → extract "tool" tag               # discriminant lookup
  → find matching variant            # ActionSchema dispatch
  → SchemaCoerce.coerce on fields    # Layer 2: type coercion (new)
  → extract optional "thinking"      # side-channel, emitted but free
  → dispatch based on tag

Returns:
  {:respond, message}                      # terminal
  {:think, thought}                        # continue, inject thought
  {:tool, name, coerced_args, tool_def, thinking: thinking}
                                           # continue, execute tool
  {:unknown, name, raw_args}               # continue, error message
  {:parse_error, reason}                   # see retry handling below
```

#### Backward compatibility

The parser accepts both the old envelope format and the new format:

- `{"thinking": "...", "action": "bash", "action_input": {"cmd": "ls"}}` —
  recognized via `"action"` key, `"action_input"` hoisted to top level,
  `"thinking"` treated as a think side-effect (emitted but doesn't cost
  a turn). Logs a repair.
- `{"tool": "bash", "cmd": "ls"}` — new format, direct dispatch.
- Key aliases (`"tool_name"`, `"name"`, `"args"`, `"input"`) — accepted
  and normalized during the transition period. Removing these aliases is
  deferred until telemetry shows they're no longer triggered. Current
  Structured accepts them and removing them would regress real fixtures.

This means existing system prompts, existing LLM behavior, and existing
test fixtures all continue to work during the transition.

#### Parse error handling

**Today, Runner treats `{:error, reason}` as terminal** (runner.ex:348-349).
There is no parse-error retry path. Before `:typed_structured` can ship:

1. Add a `:parse_error` result type to the strategy contract.
2. Runner handles `{:parse_error, reason, raw_text}` by:
   - Injecting the raw text as an assistant message
   - Injecting a correction prompt as a user message
   - Decrementing the step budget
   - Continuing the loop

```elixir
# In Runner.handle_strategy_result:
defp handle_strategy_result(
       {:parse_error, reason, raw_text},
       context,
       runtime,
       step,
       max
     ) do
  correction = "[System] Your response could not be parsed: #{reason}. " <>
    "Please respond with valid JSON matching the action schema."

  entries = [
    ReqLLM.Context.assistant(raw_text),
    ReqLLM.Context.user(correction)
  ]

  new_ctx = Context.append(context, entries)
  do_loop(new_ctx, runtime, step: step + 1, max_steps: max)
end
```

This is critical infrastructure — without it, any parse failure in
`:typed_structured` is a hard crash instead of a retry.

### Refactored `Rho.TurnStrategy.TypedStructured`

**New file**: `apps/rho/lib/rho/turn_strategy/typed_structured.ex`

The current `structured.ex` stays **completely unchanged** until
`:typed_structured` is validated via A/B testing. No code is removed
from the existing strategy until Phase 4.

**New `run/2` flow**:

```elixir
def run(projection, runtime) do
  schema = ActionSchema.build(runtime.tool_defs)
  messages = projection.context
  stream_opts = Keyword.drop(runtime.gen_opts, [:tools])

  case stream_with_retry(runtime.model, messages, stream_opts, runtime.emit, 1) do
    {:ok, text, usage} ->
      emit_usage(usage, projection, runtime)

      case ActionSchema.parse_and_dispatch(text, schema, runtime.tool_map) do
        {:respond, message} ->
          {:done, %{type: :response, text: message}}

        {:think, thought} ->
          runtime.emit.(%{type: :llm_text, text: thought})
          {:continue, build_think_step(thought)}

        {:tool, name, args, _tool_def, opts} ->
          if thinking = opts[:thinking] do
            runtime.emit.(%{type: :thinking, text: thinking})
          end
          execute_tool(name, args, runtime.tool_map, runtime)

        {:unknown, name, _args} ->
          available = Map.keys(runtime.tool_map) |> Enum.join(", ")
          error = "Unknown tool '#{name}'. Available: respond, think, #{available}"
          {:continue, build_error_step(text, error)}

        {:parse_error, reason} ->
          {:parse_error, reason, text}
      end

    {:error, reason} ->
      runtime.emit.(%{type: :error, reason: reason})
      {:error, inspect(reason)}
  end
end
```

**What stays from existing Structured** (~400 lines, shared or copied):
- `stream_with_retry` / `do_stream` / `consume_stream` / `maybe_retry_structured`
- `execute_tool` / `handle_tool_result` / `apply_tool_result_in`
- `build_tool_step_from_result` / `build_tool_step`
- `emit_thinking`
- All emit events

**What the new strategy does NOT have** (no fallback heuristics):
- `parse_action` / `parse_json_action` / `extract_action_fields`
- `@action_keys` / `@thinking_keys` / `@args_keys` (flexible key matching)
- `parse_fallback` / `extract_code_block` / `lang_to_tool` / `code_tool_args`
- `execute_action({:raw_response, ...})` re-prompt path
- `detect_format_waste` / `find_balanced_envelope` / `scan_balanced`
- `@prefill "JSON:\n"` / `strip_prefill` / `strip_prefill_once`
- `normalize_args`

These are replaced by the parse-error retry path in Runner.

### Optional: `response_format` for supporting providers

Add `response_format: %{type: "json_object"}` to `stream_opts` for
providers that support it (OpenAI, Fireworks, some OpenRouter models).
This is complementary to SAP — provider guarantees valid JSON syntax,
SAP handles semantic coercion on top. Together they should push
reliability beyond 94%.

```elixir
defp maybe_add_json_mode(opts, model) do
  if supports_json_mode?(model),
    do: Keyword.put(opts, :response_format, %{type: "json_object"}),
    else: opts
end
```

---

## Implementation Phases

### Phase 1: SchemaCoerce + ToolArgs pipeline (foundation)

**Effort**: ~150 lines implementation + ~200 lines tests + 5 call site changes
**Risk**: Low. Coercion only changes wrong-typed values. Correct values pass
through. But this is not "zero risk" — the pipeline change touches 5 call
sites and changes error handling from implicit to explicit.
**Files**:
- `apps/rho/lib/rho/schema_coerce.ex` (new)
- `apps/rho/lib/rho/tool_args.ex` (extend with `prepare/2`)
- `apps/rho/lib/rho/turn_strategy/direct.ex` (switch to `prepare/2`)
- `apps/rho/lib/rho/turn_strategy/structured.ex` (switch to `prepare/2`)
- `apps/rho/lib/rho/agent/worker.ex` (switch to `prepare/2`)
- `apps/rho/lib/rho/agent/lite_worker.ex` (switch to `prepare/2`)
- `apps/rho/lib/rho/tool/dsl.ex` (switch to `prepare/2`)
- `apps/rho/test/rho/schema_coerce_test.exs` (new)
- `apps/rho/test/rho/tool_args_test.exs` (extend)

**Work**:
1. Implement `SchemaCoerce.coerce/2` for all NimbleOptions types used in
   parameter_schemas: `:string`, `:integer`, `:pos_integer`, `:float`,
   `:number`, `:boolean`, `{:list, inner}`, `:map`, `{:map, opts}`,
   `{:in, variants}`. No `:atom` — whitelist-only via `{:in, [atoms]}`.
2. Implement object unwrapping with known keys only (`:tool_call` mode).
3. Implement `coerce_fields/3` with repair log.
4. Implement `ToolArgs.prepare/2` orchestrating `cast → coerce → validate`.
5. Add telemetry on `[:rho, :tool, :args_coerced]`.
6. Migrate all 5 call sites to `ToolArgs.prepare/2`.
7. Port test cases from `simplify_baml/src/parser.rs` (lines 564+).
8. Add property test: for any value already matching the expected type,
   `coerce(value, type) == {:ok, value, []}` (no false positives).
9. Add cross-path integration tests proving the same coercion happens in
   Direct, Structured, LiteWorker, Worker, and DSL paths.

**Rollback**: Revert `prepare/2` calls to `cast/2` at each call site.

### Phase 2: ActionSchema + collision detection

**Effort**: ~120 lines implementation + ~120 lines tests
**Risk**: Low. New module, not wired into any strategy yet.
**Files**:
- `apps/rho/lib/rho/action_schema.ex` (new)
- `apps/rho/test/rho/action_schema_test.exs` (new)

**Work**:
1. Implement `build/1` — construct tagged union from tool_defs, add `respond`
   and `think` built-in variants.
2. **Collision detection** — fail fast on reserved name collisions and
   duplicate tool names at build time.
3. Implement `parse_and_dispatch/3` — StructuredOutput.parse → extract tag →
   SchemaCoerce.coerce → dispatch.
4. Backward compat: accept `"action"`/`"action_input"` envelope and key
   aliases (`"tool_name"`, `"name"`, `"args"`, `"input"`) with repair logging.
5. Implement `render_prompt/1` — BAML-style schema text for prompt injection.
6. Test with mock tool_defs. Test that old envelope format parses correctly.
7. Test collision detection raises on reserved names and duplicates.

### Phase 3: Runner parse-error retry + TypedStructured strategy

**Effort**: ~60 lines Runner change + new strategy file (~200 lines)
**Risk**: Medium. Changes core loop contract and adds a new strategy.
**Mitigation**: Register as `turn_strategy: :typed_structured`. Keep
`:structured` unchanged. Both coexist.
**Files**:
- `apps/rho/lib/rho/runner.ex` (add `:parse_error` handling)
- `apps/rho/lib/rho/turn_strategy/typed_structured.ex` (new)

**Work**:
1. Add `handle_strategy_result({:parse_error, reason, raw_text}, ...)` to
   Runner — injects correction prompt, decrements budget, continues loop.
2. New `TypedStructured` strategy using `ActionSchema.parse_and_dispatch`.
3. Shared streaming infrastructure: extract common streaming code from
   existing `Structured` into a shared module or use delegation.
4. `thinking` as optional side-channel on any action, plus standalone
   `think` variant.
5. `prompt_sections/2` using `ActionSchema.render_prompt`.
6. Retain correction/fallback logic via the Runner retry path (not
   inline heuristics).

### Phase 4: Validation, rollout, and cleanup

**Effort**: Testing, tuning, and eventual cleanup
**Work**:
1. Run spreadsheet agent with `:typed_structured`, compare to `:structured`.
2. **Metrics to collect**:
   - Re-prompt cycles per task
   - Token usage per turn
   - Task completion rate
   - Coercion repair frequency by tool/field (from telemetry)
   - Parse error rate and recovery rate
   - Whether repairs correlate with better completion
3. If `:typed_structured` is equal or better, make it the default.
4. Monitor key alias telemetry — only remove backward-compat aliases after
   data shows they're not triggered.
5. Delete `:structured` only after `:typed_structured` is proven stable.

### Phase 5 (optional): response_format

**Effort**: ~20 lines
**Work**: Detect provider support, add `response_format` to stream_opts.
Complementary to SAP, not required.

### Phase 6 (deferred): Schema-aware streaming

From the original plan's Phase 7. Emit structured streaming events:
`:action_detected`, `:action_input_list_item`, etc. Only build if the
skill-framework list-rendering UX needs it.

### Phase 7 (deferred): Multi-action

From the original plan's Phase 7.5. Allow `actions: Action[]` instead of
single action per turn. Only build if latency from 1-action-per-turn
becomes a measured problem.

---

## Testing strategy

### Unit tests (Phase 1)

- Every coercion rule from the table above: positive and negative cases.
- Property test: `∀ value matching type, coerce(value, type) == {:ok, value, []}`.
- Required-field safety: `nil` on required string → `{:error, ...}`, not `""`.
- Ambiguity tests: single-field unwrap NOT triggered in `:tool_call` mode.
- Repair log correctness: verify repairs list records what changed.

### Cross-path integration tests (Phase 1)

Prove that the same coercion happens regardless of which execution path
is used. Create a test tool with schema `[count: [type: :integer]]` and
call it with `%{"count" => "5"}` through each path:

- Direct strategy dispatch
- Structured strategy execute_tool
- DSL-generated tool execute
- Worker direct command
- LiteWorker execute_single_tool

All 5 should produce `%{count: 5}` with the same repair log.

### ActionSchema tests (Phase 2)

- Collision detection: reserved names, duplicate names.
- Old envelope format → correct dispatch.
- Key alias normalization.
- Unknown tool → `{:unknown, name, args}`.
- Malformed JSON → `{:parse_error, reason}`.

### Strategy tests (Phase 3)

- Parse error → Runner injects correction → retry succeeds.
- Parse error budget exhaustion → terminal error.
- `thinking` side-channel extraction on tool calls.
- Standalone `think` variant.
- `respond` terminal action.

### Regression corpus (Phase 4)

- Run existing test fixtures through `:typed_structured`.
- A/B comparison on real agent tasks.
- Monitor telemetry for chronic coercion offenders.

---

## Line count estimate

| Component | Current | After | Delta |
|-----------|---------|-------|-------|
| `SchemaCoerce` (new) | 0 | ~150 | +150 |
| `ToolArgs` (extended) | 89 | ~130 | +41 |
| `ActionSchema` (new) | 0 | ~120 | +120 |
| `TypedStructured` (new) | 0 | ~200 | +200 |
| `Runner` (parse-error) | 450 | ~470 | +20 |
| `TurnStrategy.Structured` | 743 | 743 | 0 (unchanged until Phase 4) |
| `TurnStrategy.Direct` | 384 | ~388 | +4 |
| `StructuredOutput` | 537 | 537 | 0 |
| Tests (new) | 0 | ~400 | +400 |
| **Total production code delta** | | | **+535 initially, -300 after Phase 4 cleanup** |

More code initially because we keep both strategies. After validation,
removing `:structured` yields ~340 lines deleted, bringing net to ~+195
production lines for significantly better reliability.

---

## Risk assessment

| Phase | Risk | Mitigation |
|-------|------|------------|
| 1 (SchemaCoerce + pipeline) | Low | Property test confirms no false positives. Telemetry tracks repairs. Rollback = revert 5 call sites to `cast/2`. |
| 2 (ActionSchema) | Low | New module, not wired in yet. Pure unit tests. Collision detection catches naming issues early. |
| 3 (Runner + TypedStructured) | Medium | Feature flag: `:typed_structured` vs `:structured`. Old strategy unchanged. Parse-error retry prevents hard crashes. |
| 4 (Validation) | Low | A/B comparison with metrics, not a blind switch. Alias removal gated on telemetry data. |
| 5 (response_format) | Low | Provider-specific, fallback for non-supporting providers. |

### Known risks and guardrails

| Risk | Guardrail |
|------|-----------|
| `nil → ""` bypasses required-field validation | ❌ Blocked: nil on required field → `{:error, :missing_required}` |
| Arbitrary atom creation from LLM input (BEAM DoS) | ❌ Blocked: no `:atom` coercion. Atoms only via `{:in, [atom_list]}` |
| Over-liberal object unwrap changes semantics | Strict: known wrapper keys only in `:tool_call` mode |
| Silent coercion masks bugs | Telemetry on every repair. Both raw and prepared args stored in tape |
| `respond`/`think` collide with plugin tools | Fail-fast at `ActionSchema.build/1` time |
| Duplicate tool names silently ignored | Fail-fast at `ActionSchema.build/1` time |
| Parse failure = hard crash | Runner parse-error retry path (Phase 3) |
| Removing key aliases regresses real usage | Aliases kept until telemetry shows zero triggers |

---

## Success criteria

1. **Phase 1**: All existing tests pass. SchemaCoerce tests cover every
   coercion rule. Property test: no false positives. All 5 execution
   paths produce identical coercion results.

2. **Phase 3**: `:typed_structured` strategy handles parse errors
   gracefully via Runner retry. No hard crashes on malformed output.

3. **Phase 4**: Spreadsheet agent on `:typed_structured` completes same
   tasks with equal or fewer re-prompt cycles than `:structured`. Token
   usage per turn decreases. Coercion repair telemetry shows which
   tools/fields benefit most.

4. **Overall**: The structured strategy becomes reliable enough that the
   improvement-loop-round1.md finding ("structured is unreliable, switch
   to direct") no longer applies. `:typed_structured` becomes the
   recommended default for agents needing streaming visibility and
   visible reasoning. The strict typed protocol ensures every LLM
   response has a well-defined dispatch path with no ambiguity.

---

## References

- BoundaryML blog post: https://boundaryml.com/blog/schema-aligned-parsing
- simplify_baml parser source: `/Users/catethos/workspace/simplify_baml/src/parser.rs`
- simplify_baml IR: `/Users/catethos/workspace/simplify_baml/src/ir.rs`
- simplify_baml schema formatter: `/Users/catethos/workspace/simplify_baml/src/schema.rs`
- Tao agent tools: `/Users/catethos/workspace/tao/crates/tao-core/src/tools.rs`
- Tao LLM integration: `/Users/catethos/workspace/tao/crates/tao-core/src/llm.rs`
- GenBAML schema DSL: `/Users/catethos/workspace/ds-agents/.../genbaml/lib/genbaml/schema.ex`
- GenBAML runtime: `/Users/catethos/workspace/ds-agents/.../genbaml/lib/genbaml/runtime.ex`
- Rho existing structured strategy: `apps/rho/lib/rho/turn_strategy/structured.ex`
- Rho existing structured output parser: `apps/rho/lib/rho/structured_output.ex`
- Rho improvement loop findings: `docs/improvement-loop-round1.md`
- Previous plan version (v2): git history of this file
