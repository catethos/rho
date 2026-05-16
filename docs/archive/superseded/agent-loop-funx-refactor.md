> **Superseded.** The agent loop is now `Rho.Runner` (outer loop) +
> `Rho.TurnStrategy` (inner turn). `Rho.Lifecycle` is deleted;
> Runner calls `PluginRegistry.apply_stage/3` directly. See CLAUDE.md.

# Agent Loop Refactor — Funx Functional Patterns

## Problem

The agent loop (`lib/rho/agent_loop.ex`) and reasoner (`lib/rho/reasoner/direct.ex`) have hook points and extension mechanisms that are not explicit in the code structure. The mount lifecycle is cleanly defined in `Rho.Mount`, but invocation is scattered and hidden behind helper names that obscure intent.

### Current hook invocation map

```
Mount.behaviour defines:          Actually invoked in:
─────────────────────────         ─────────────────────────────────────
prompt_sections/2  ───────────►   agent_loop.ex:build_system_prompt/3   (setup, before loop)
bindings/2         ───────────►   agent_loop.ex:build_system_prompt/3   (setup, before loop)
before_llm/3       ───────────►   agent_loop.ex:apply_before_llm/2      (hidden inside helper)
before_tool/3      ───────────►   reasoner/direct.ex:handle_tool_calls  (buried in Enum.map)
after_tool/4       ───────────►   reasoner/direct.ex:handle_tool_calls  (buried in Enum.map)
after_step/4       ───────────►   agent_loop.ex:collect_injected_messages (name hides intent)
```

### Specific issues

1. **Hooks hidden inside helpers** — `apply_before_llm` wraps a single dispatch call. `collect_injected_messages` is actually "run the after_step hooks". Names obscure what's happening.
2. **Hooks split across two modules** — `before_tool`/`after_tool` live in the reasoner, `before_llm`/`after_step` live in the agent loop. No single place shows the full lifecycle.
3. **Reasoner coupled to MountRegistry** — `Reasoner.Direct` calls `MountRegistry.dispatch_before_tool` and `dispatch_after_tool` directly, making it hard to test or swap.
4. **Observability (`emit_event`) is a cross-cutting concern** — it sits outside the pipeline as a bare side effect, not represented in any structural way.
5. **Errors silently swallowed** — `maybe_compact` catches `{:error, _}` and returns the original context with no signal.

---

## Proposal 1: Lifecycle as a First-Class Value

Extract all hook dispatch into a `Rho.Lifecycle` struct built once at loop start. The reasoner receives hook functions as parameters instead of reaching into `MountRegistry` directly.

```elixir
defmodule Rho.Lifecycle do
  defstruct [
    :before_llm,    # (projection, context) -> projection
    :before_tool,   # (call, context) -> :ok | {:deny, reason}
    :after_tool,    # (call, result, context) -> result
    :after_step,    # (step, max, context) -> :ok | {:inject, msgs}
    :emit           # (event) -> :ok
  ]

  def from_mounts(context, emit) do
    %__MODULE__{
      before_llm:  &Rho.MountRegistry.dispatch_before_llm(&1, context),
      before_tool: &Rho.MountRegistry.dispatch_before_tool(&1, context),
      after_tool:  fn call, result -> Rho.MountRegistry.dispatch_after_tool(call, result, context) end,
      after_step:  &Rho.MountRegistry.dispatch_after_step(&1, &2, context),
      emit:        emit
    }
  end

  def noop do
    %__MODULE__{
      before_llm:  fn projection, _ctx -> {:ok, projection} end,
      before_tool: fn _call, _ctx -> :ok end,
      after_tool:  fn _call, result, _ctx -> result end,
      after_step:  fn _step, _max, _ctx -> :ok end,
      emit:        fn _event -> :ok end
    }
  end
end
```

### What this buys

- **The lifecycle is inspectable, testable, swappable.** A mount-free agent passes `Lifecycle.noop()`.
- **The reasoner is decoupled from MountRegistry.** It calls functions it's given, doesn't know where they came from.
- **Emit becomes a lifecycle concern**, not a stray side effect. Stages call `lifecycle.emit` at defined points.

---

## Proposal 2: Either Pipeline for Single-Step Stages

Use Funx's `Either` monad to make each iteration's stages into an explicit, error-propagating pipeline. The pipeline covers one iteration; recursion stays outside it as a plain `case`.

```elixir
use Funx.Monad.Either

defp do_loop(context, loop_opts, lifecycle, step: step, max_steps: max, prev_tools: prev)
     when step > max do
  {:error, "max steps exceeded (#{max})"}
end

defp do_loop(context, loop_opts, lifecycle, step: step, max_steps: max, prev_tools: prev) do
  # Either pipeline covers one iteration — each stage is visible
  result =
    either context do
      map  emit_step_start(lifecycle, step, max)
      bind compact_tape(loop_opts)
      bind run_hook(:before_llm, lifecycle)
      bind reason_and_act(loop_opts, lifecycle, step)
      bind record_step(loop_opts)
      bind run_hook(:after_step, lifecycle, step, max)
    end

  # Recursion decision is outside the pipeline
  case result do
    {:right, {:done, text}} ->
      {:ok, text}

    {:right, {:continue, entries, new_context}} ->
      do_loop(new_context, loop_opts, lifecycle,
        step: step + 1, max_steps: max,
        prev_tools: extract_tool_names(entries))

    {:left, error} ->
      {:error, error}
  end
end
```

### Why recursion stays outside

The Either pipeline is linear — it terminates, it doesn't recurse. The continue/done/error branching after a step is a domain decision (should we loop again?), not monadic composition. Recursion happens in two places today:

- **`:continue` with `:tool_step`** → increments step, checks for repeated tools, recurses
- **`:continue` with `:subagent_nudge`** → injects nudge message, recurses

Both need to prepare state for the next iteration before recursing, which is control flow, not a pipeline stage.

### What this buys

- **Error propagation is explicit.** If `compact_tape` or `before_llm` fails, the pipeline short-circuits. No more silent swallowing.
- **The pipeline spine is the documentation.** Reading `do_loop` top-to-bottom shows the exact hook sequence, matching what `Rho.Mount` defines.

---

## Proposal 3: Reader Monad for Environment Threading

`loop_opts` is a fat map threaded through every function — `maybe_compact`, `apply_before_llm`, `run_reasoner`, `emit_event`, `append_to_tape`, `rebuild_tape_context` all receive it just to destructure a few fields. This is the pattern Reader solves.

```elixir
# Current — loop_opts passed everywhere:
defp maybe_compact(context, loop_opts) do
  %{memory_mod: mem, tape_name: tape, model: model, ...} = loop_opts
  ...
end

# With Reader — environment is implicit:
defp maybe_compact(context) do
  Reader.ask() |> Reader.bind(fn %{memory_mod: mem, tape_name: tape, ...} ->
    ...
  end)
end
```

### Assessment

This is architecturally interesting but the **highest-friction change**. It would make the code less familiar to Elixir developers who expect explicit argument passing. The Lifecycle struct (Proposal 1) solves the more important problem (hook visibility) without this trade-off.

**Recommendation:** defer this unless `loop_opts` grows further.

---

## Proposal 4: Predicates for Termination Logic

The repeated-tool-call detection and max-steps guard could be expressed as composable predicates if more termination conditions are added in the future.

```elixir
use Funx.Predicate

should_terminate = pred do
  any do
    check :repeated_tools, IsTrue
    check :max_steps_exceeded, IsTrue
  end
end
```

### Assessment

Currently there are only two termination conditions, and pattern matching handles them cleanly. This would only pay off if termination logic becomes more complex (e.g., budget-based, time-based, token-based conditions). **Defer until needed.**

---

## Where Funx Would NOT Help

- **The recursive loop itself** — pattern matching on `:continue`/`:done`/`:error` variants is already idiomatic Elixir.
- **Tape recording side effects** — intentional and local. Effect monad would add ceremony without benefit.
- **`resolve_emit`** — a simple case expression. No gain from abstraction.

---

## Recommended Priority

1. **Lifecycle struct** (Proposal 1) — highest value, lowest risk. Decouples reasoner from MountRegistry, makes hooks testable, gives emit a home.
2. **Either pipeline** (Proposal 2) — makes stage ordering and error propagation explicit. Depends on Funx as a dependency.
3. **Reader monad** (Proposal 3) — defer unless loop_opts grows.
4. **Predicates** (Proposal 4) — defer until termination logic grows.

Proposal 1 can be done independently of Funx. Proposal 2 is where the library adds real value.
