# BAML Action Union — Implementation Plan

## Problem

`Rho.TurnStrategy.TypedStructured` generates a single flat `Action` BAML class with every tool's parameters flattened and made `?`-optional. With ~20+ tools mounted, the class has 50+ optional fields. The LLM (especially Haiku 4.5) emits all declared fields in its JSON output — most as `null` — wasting ~1k output tokens per turn.

Source of waste: `apps/rho_baml/lib/rho_baml/schema_writer.ex:81-89` (`to_baml/2` builds one flat class).

Generated example: `apps/rho/priv/baml_src/dynamic/action.baml` shows the 50-field class.

## Goal

Replace the flat class with a BAML **discriminated union** — one class per tool, each declaring only its own params. The LLM picks one variant and emits only its fields. Same external semantics for `Rho.ActionSchema.dispatch_parsed/3`.

Expected savings: 60–90% of structured-output token cost per turn.

## Verified prerequisites

- `baml_elixir ~> 1.0.0-pre.27` supports unions: see `deps/baml_elixir/lib/baml_elixir/client.ex:434-435` (`{:union, types} -> # Convert union to pipe operator`). Confirmed in `to_elixir_type/2`.
- `Rho.ActionSchema.dispatch_parsed/3` (`apps/rho/lib/rho/action_schema.ex:118-154`) already dispatches on `Map.get(parsed, "tool")` — works as long as each variant carries a `tool` field. No changes needed if BAML returns parsed variants as plain maps with `"tool"` populated.

## Implementation

### Step 1 — Spike: verify BAML behavior with a small union

**Goal:** confirm that `baml_elixir` correctly parses a tagged union with literal-discriminant fields and returns a map containing the discriminant value, without us having to dispatch on Elixir struct names.

**Action:** create a one-off test script (or extend `apps/rho_baml/test/`) with two classes:

```baml
class FooAction {
  tool "foo"
  x string
}
class BarAction {
  tool "bar"
  y int
}
function Pick(input: string) -> FooAction | BarAction { ... }
```

Call it twice (once for each shape) and inspect:
- Does the parsed result include `"tool" => "foo"` or just `%FooAction{x: ...}`?
- If a struct, what's the module name? Does `clean_baml_result/1` need to handle structs?

**Decision point:** if BAML returns a struct without the literal `tool` field as a map key, we have two options:
- (a) Strip struct → map and re-derive `tool` from `__struct__` name.
- (b) Use a regular `tool string` field instead of literal — slightly weaker discrimination but the LLM still sets it, and our existing `dispatch_parsed/3` works unchanged.

If unsure after the spike, default to (b) — minimal blast radius.

**Files touched:** none in production (spike script can be discarded).

**Estimated time:** 30–60 min.

### Step 2 — Rewrite `Rho.SchemaWriter.to_baml/2`

**Current (flat):** one `class Action` with all fields, function returns `Action`.

**New (union):** one class per tool variant, function returns the union.

```elixir
def to_baml(tool_defs, opts \\ []) do
  client = Keyword.get(opts, :client, "OpenRouter")
  visible_defs = Enum.reject(tool_defs, fn td -> td[:deferred] end)

  # Built-in variants
  reserved = [
    {"RespondAction", "respond", [{"message", "string"}]},
    {"ThinkAction", "think", [{"thought", "string"}]}
  ]

  # Tool variants
  tool_variants =
    Enum.map(visible_defs, fn td ->
      class_name = tool_name_to_class(td.tool.name)  # "bash" -> "BashAction"
      fields = render_variant_fields(td.tool.parameter_schema || [])
      {class_name, td.tool.name, fields}
    end)

  all_variants = reserved ++ tool_variants

  classes_baml =
    Enum.map_join(all_variants, "\n\n", fn {class_name, tool_lit, fields} ->
      build_variant_class(class_name, tool_lit, fields)
    end)

  union_type =
    all_variants
    |> Enum.map(&elem(&1, 0))
    |> Enum.join(" | ")

  tool_catalog = build_tool_catalog(visible_defs)

  """
  #{classes_baml}

  function AgentTurn(messages: string) -> #{union_type} {
    client #{client}
    prompt #"
      {{ messages }}

      Available actions:
      #{tool_catalog}

      {{ ctx.output_format }}
    "#
  }
  """
end

defp build_variant_class(class_name, tool_lit, fields) do
  fields_baml = Enum.map_join(fields, "\n", fn {n, t} -> "  #{n} #{t}" end)
  """
  class #{class_name} {
    tool "#{tool_lit}"
  #{fields_baml}
    thinking string?
  }
  """
end
```

**Notes:**
- Each variant declares `tool "<name>"` as a literal-string field (BAML supports literal types). If the spike (Step 1) shows literals don't work cleanly, fall back to `tool string` — the LLM will still emit the right value because the prompt + variant fields constrain it.
- Required vs optional in per-variant fields: now we can mark required params as required (`field string` instead of `field string?`). Currently they were all `?` because flattening made it impossible to distinguish per-tool requirements. **This is a side benefit** — better LLM compliance.
- `thinking` stays on every variant as `string?` (preserves the side-channel).
- Class naming: `tool_name_to_class("generate_framework_skeletons")` → `"GenerateFrameworkSkeletonsAction"`. Use `Macro.camelize/1`.
- `build_tool_catalog/1` (line 107) — the existing tool catalog moves from the `@description` on `tool` to the function prompt itself, since there's no single `tool` field anymore. Keep the catalog (LLM still benefits from descriptions).

**Files touched:**
- `apps/rho_baml/lib/rho_baml/schema_writer.ex` — rewrite `to_baml/2`, add `build_variant_class/3`, `tool_name_to_class/1`. Drop `collect_fields/1` (no longer flat). Keep type mapping helpers.

**Estimated time:** 2–3 hours.

### Step 3 — Update `Rho.ActionSchema.dispatch_parsed/3`

**Current behavior:** reads `Map.get(parsed, "tool")` for tag, drops the tag and `"thinking"`, treats the remainder as args.

**Required behavior with union:** identical, *if* BAML returns variants as plain maps with `"tool"` populated. Step 1 confirms.

**If BAML returns structs:** add a normalizer that converts `%SomeAction{}` → plain map with string keys. Likely a 5-line helper in `clean_baml_result/1`.

**Files touched (likely none, possibly):**
- `apps/rho/lib/rho/turn_strategy/typed_structured.ex` — extend `clean_baml_result/1` to strip struct wrapper if needed. Existing nil-stripping stays as defensive cleanup.

**Estimated time:** 15–60 min depending on Step 1 outcome.

### Step 4 — Tests

- `apps/rho/test/rho/action_schema_test.exs` — should pass unchanged (it tests dispatch logic, not BAML).
- Add `apps/rho_baml/test/rho_baml/schema_writer_test.exs` (currently absent — `find` confirms only `schema_compiler_test.exs` exists). Cover:
  - Single tool → emits one variant + builtins, function returns union of three.
  - Multiple tools → emits N+2 variants, union has all.
  - Required vs optional fields preserved in variants.
  - Class naming snake_case → CamelCase + "Action" suffix.
  - Deferred tools excluded from variants AND union.
- Update `apps/rho/test/rho/turn_strategy/typed_structured_test.exs` (if exists) — verify end-to-end dispatch with new schema. Use a recorded BAML response or live call against the spike's class.

**Estimated time:** 1–2 hours.

### Step 5 — Verify in running app

- Start `mix phx.server`, open the spreadsheet agent.
- Run "create a minimal framework on a general chef" (the same scenario from prior session).
- Inspect the generated `apps/rho/priv/baml_src/dynamic/action.baml` — confirm union shape.
- Inspect `:structured_partial` events in chat (or tape entry) — confirm only relevant fields appear, no `null` padding.
- Compare LLM `output_tokens` from `:llm_usage` events vs. before. Expect 60–90% reduction.

**Estimated time:** 30 min.

### Step 6 — Cleanup

- Drop now-dead code in `schema_writer.ex` (the flat-class branch, `collect_fields/1`, `unique_fields` dedup).
- Update `apps/rho_baml/lib/rho_baml/schema_writer.ex` `@moduledoc` to describe the new union shape.
- Update CLAUDE.md `apps/rho_baml/` section — "Emits a flat `Action` class" → "Emits a discriminated union of per-tool action classes".

**Estimated time:** 30 min.

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| BAML literal-typed fields don't work / aren't supported in `1.0.0-pre.27` | Medium | Fallback to `tool string` (Step 1 fallback (b)) |
| Union dispatch returns struct, not map; downstream breaks silently | Low–Medium | Spike (Step 1) flushes this out; one-line normalizer in `clean_baml_result/1` |
| Some LLM (e.g. older OpenRouter routes) doesn't pick the right variant | Low | The reserved tool catalog stays in the prompt; the union narrows the schema, which usually *helps* compliance |
| `coerce_variant_fields/2` in `ActionSchema` mis-coerces newly-required fields (used to be all optional) | Low | Existing tests in `action_schema_test.exs` cover coercion; add a per-variant fixture if needed |
| Streaming partials behave differently (partial union variant) | Medium | Step 5 verification covers this; if partials only emit when variant is settled, the chat UI may feel less "live" — acceptable trade-off |

## Out of scope (explicitly defer)

- Switching to `:direct` turn strategy — separate decision, doesn't conflict with this work.
- Fixing the streaming buffer accumulation in `session_state.ex:270` (`entry.chunks ++ [text]`) — independently broken, but separate fix.
- Changing the `respond` / `think` reserved variants' semantics.

## Total estimate

~5–7 hours, including spike, tests, and verification. Single-session feasible.

## Files to touch (summary)

- `apps/rho_baml/lib/rho_baml/schema_writer.ex` — rewrite `to_baml/2`
- `apps/rho/lib/rho/turn_strategy/typed_structured.ex` — possibly extend `clean_baml_result/1` (depends on Step 1)
- `apps/rho_baml/test/rho_baml/schema_writer_test.exs` — new
- `apps/rho/test/rho/turn_strategy/typed_structured_test.exs` — update if present
- `CLAUDE.md` — update `rho_baml` section description
