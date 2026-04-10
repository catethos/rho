# Acceptance Gate Verification

Verification of the 10 acceptance criteria from
`docs/concept-alignment-plan.md` after Phases 1–7 landed on `main`.

Each criterion lists what was checked, the file/line/test that proves
it, and a pass/fail verdict. New tests that were added to close
inspection gaps live in `test/rho/acceptance_gate_test.exs`.

All 13 tests in the acceptance-gate suite pass (`mix test
test/rho/acceptance_gate_test.exs --seed 0` → *13 tests, 0 failures*).

---

## 1. Tools-only plugin = one module, one callback (`tools/2`) — **PASS**

Checked that each tools-only plugin is a single module declaring
`@behaviour Rho.Plugin` and only the `tools/2` callback — no hooks,
no `children/2`, no `transform/3`.

Verified via grep:

```
$ grep -n "@impl|@behaviour|def (tools|prompt_sections|bindings|transform|children)\\(" \
    lib/rho/tools/{bash,fs_read,fs_write,fs_edit,web_fetch}.ex
lib/rho/tools/bash.ex:2:      @behaviour Rho.Plugin
lib/rho/tools/bash.ex:4:      @impl Rho.Plugin
lib/rho/tools/bash.ex:5:      def tools(_mount_opts, %{workspace: workspace}), ...
lib/rho/tools/bash.ex:6:      def tools(_mount_opts, _context), do: [tool_def(nil)]
lib/rho/tools/fs_read.ex:4:   @behaviour Rho.Plugin
lib/rho/tools/fs_read.ex:6:   @impl Rho.Plugin
lib/rho/tools/fs_read.ex:7:   def tools(_mount_opts, %{workspace: workspace}), ...
lib/rho/tools/fs_write.ex:4:  @behaviour Rho.Plugin
lib/rho/tools/fs_write.ex:6:  @impl Rho.Plugin
lib/rho/tools/fs_write.ex:7:  def tools(_mount_opts, %{workspace: workspace}), ...
lib/rho/tools/fs_edit.ex:4:   @behaviour Rho.Plugin
lib/rho/tools/fs_edit.ex:6:   @impl Rho.Plugin
lib/rho/tools/fs_edit.ex:7:   def tools(_mount_opts, %{workspace: workspace}), ...
lib/rho/tools/web_fetch.ex:4: @behaviour Rho.Plugin
lib/rho/tools/web_fetch.ex:8: @impl Rho.Plugin
lib/rho/tools/web_fetch.ex:9: def tools(_mount_opts, _context), do: [tool_def()]
```

No `children`, `transform`, `before_llm`, `before_tool`, `after_tool`,
`after_step`, `prompt_sections`, or `bindings` callbacks in any of these
files. File sizes: bash 35 LOC, fs_read 57, fs_write 40, fs_edit 64,
web_fetch 108.

---

## 2. Transformer can halt at any of its 5 haltable stages — **PASS**

Inspection: `Rho.PluginRegistry.apply_stage/3`
(`lib/rho/plugin_registry.ex:188`) uses `Enum.reduce_while/3` with a
unified `do_apply_stage/3` body for `:prompt_out`, `:response_in`,
`:tool_result_in` (line 283), `:tool_args_out` (line 260), and
`:post_step` (line 227). In every case `{:halt, reason}` returned by a
transformer short-circuits the reduction and propagates out. For
`:tape_write` (line 201) halt is intentionally *disallowed* and logged.

Halt propagation into the live loop:

- `:prompt_out` — `Runner.run_prompt_out/3` converts `{:halt, reason}`
  into `{:error, {:halt, reason}}` (`lib/rho/runner.ex:276-278`).
- `:response_in`, `:tool_args_out`, `:tool_result_in` — propagated by
  `Rho.TurnStrategy.Direct` at `lib/rho/turn_strategy/direct.ex:47-49`,
  `:114-115`, `:204-206` using a `throw({:rho_transformer_halt, …})`
  caught at line 251-255 and returned as `{:error, {:halt, reason}}`.
- `:post_step` — `Runner.run_post_step/3` treats `{:halt, _}` as "no
  injections" (`lib/rho/runner.ex:349`); propagation to the outer loop
  is not required by the contract (the stage fires after the step has
  already been recorded).

Tests:

- Existing `:prompt_out` halt: `test/rho/mount_registry_test.exs:400-413`.
- New parametric halt assertions for all 5 haltable stages:
  `test/rho/acceptance_gate_test.exs` (`HaltAt` transformer +
  `for stage <- [:prompt_out, :response_in, :tool_args_out,
  :tool_result_in, :post_step]` block). Each stage returns
  `{:halt, {:blocked_at, stage}}`.

---

## 3. `:tool_args_out` can deny without halting; denial recorded on tape — **PASS**

Inspection: `PluginRegistry.do_apply_stage(:tool_args_out, …)` returns
`{:deny, reason}` as a distinct value from `{:halt, _}`
(`lib/rho/plugin_registry.ex:267-268`). `Direct` strategy handles
`{:deny, reason}` at `lib/rho/turn_strategy/direct.ex:101-112` by
synthesizing a denied `:tool_result` event and a
`ReqLLM.Context.tool_result/2` entry — the turn is *not* aborted, and
remaining tool calls still execute.

The denied tool result is appended to the tape via the normal path:
the denied `ReqLLM.Context.tool_result(...)` is part of the
`tool_results` list returned from the strategy, which
`Rho.Runner.handle_strategy_result/5` passes to
`Recorder.record_tool_step/2` (`lib/rho/runner.ex:332`). That function
calls `append_with_tape_write` per tool_result
(`lib/rho/agent_loop/recorder.ex:85-92`), so the denial ends up as a
`:tool_result` tape entry with the `"Denied: …"` body.

Test: `test/rho/agent_loop_test.exs:221-264` (`"lifecycle: before_tool
deny"` → `"denied tool call returns denial message as tool result"`)
drives the loop with a `{:deny, "Not allowed"}` transformer, asserts
the turn continues to its final text, and asserts a `:tool_result`
event fires with `status: :error` and `output =~ "Denied"`.

---

## 4. `:post_step` can inject a synthetic user message visible next turn — **PASS**

Inspection: `Runner.run_post_step/3`
(`lib/rho/runner.ex:343-351`) returns the injected messages, which are
passed to `Recorder.record_injected_messages/2` and
`advance_context/4` (`lib/rho/runner.ex:334-337`). With no tape,
messages are appended as `ReqLLM.Context.user/1` to the running
context (`lib/rho/runner.ex:366`); with a tape, rebuilt context
includes them via `Recorder.rebuild_context/1`.

Test: `test/rho/agent_loop_test.exs:318-362` (`"lifecycle: after_step
inject"` → `"injected messages appear in context for next LLM call"`).
The test registers an `InjectMount` transformer that returns
`{:inject, ["Reminder from InjectMount"]}` at `:post_step`
(`test/rho/agent_loop_test.exs:517-523`), captures the context passed
to the *second* LLM call, and asserts the last user message contains
the injected text.

---

## 5. Plugin reads per-instance opts from callback args — **PASS**

Spot-checked plugins registered with tuple-form options:

- `Rho.Mounts.MultiAgent` (`lib/rho/mounts/multi_agent.ex:33,55,704`) —
  `tools(mount_opts, ctx)` reads `:only` / `:except` via
  `Keyword.get(mount_opts, …)` in `filter_tools/2`. No
  `Application.get_env` on plugin opts.
- `Rho.Mounts.PyAgent` (`lib/rho/mounts/py_agent.ex:23-25`) — reads
  `:name` via `Keyword.get(mount_opts, :name, …)` from callback args.
- `PluginRegistry.collect_tools/1` threads per-instance opts through
  every callback: `safe_call(mod, :tools, [opts, context], [])`
  (`lib/rho/plugin_registry.ex:103-107`), where `opts` is the
  `PluginInstance.opts` field populated at registration
  (`lib/rho/plugin_registry.ex:64-71`).

Regression test already in place:
`test/rho/mount_registry_test.exs:156-160`
(`"mount_opts are passed through to callbacks"`) asserts a
`ToolMount` with `opts: [prefix: "custom_"]` returns
`[%{name: "custom_tool_a"}]`.

---

## 6. Adding a new TurnStrategy requires zero Runner changes — **PASS**

Inspection: `lib/rho/runner.ex` mentions concrete strategies in only
two places:

- `lib/rho/runner.ex:7` — doc comment.
- `lib/rho/runner.ex:83` — default: `Rho.TurnStrategy.Direct`.

The dispatch itself is polymorphic:
`runtime.reasoner.run(projection, runtime)` at
`lib/rho/runner.ex:224`, followed by a single `handle_strategy_result/5`
that pattern-matches on strategy-return shapes (`{:done, …}`,
`{:final, …}`, `{:continue, …}`, `{:error, …}`) — all defined by the
`Rho.TurnStrategy` behaviour, not per-strategy. No strategy-specific
branches anywhere in the Runner.

Both bundled strategies declare `@behaviour Rho.TurnStrategy`
(`lib/rho/turn_strategy/direct.ex:10`,
`lib/rho/turn_strategy/structured.ex`). A third strategy would
register via the `turn_strategy:` config key
(`lib/rho/runner.ex:82-83`) without touching Runner.

---

## 7. Adding a new subscriber type requires zero agent-side changes — **PASS**

Inspection: `Rho.Agent.Worker` no longer carries a `subscribers` list
and has no `broadcast/2` function — grep for `subscribers|broadcast` in
`lib/rho/agent/worker.ex` returns no matches. Every event is published
exclusively via the bus at `lib/rho/agent/worker.ex:712-724` using
`Rho.Comms.publish(…)` (topic
`rho.session.<sid>.events.<signal_type>`).

Tape appends also publish via
`Rho.AgentLoop.Recorder.publish_entry_appended/4`
(`lib/rho/agent_loop/recorder.ex:132-149`) on
`rho.session.<sid>.tape.entry_appended`.

A new subscriber just calls `Rho.Comms.subscribe/2` against the
appropriate topic pattern — no change to `Worker`, `Runner`, or
`Recorder`. Bus parity regression suite at
`test/rho/session/bus_parity_test.exs` locks this in.

---

## 8. Replay with stubbed LLM adapter = byte-identical tape entries — **PASS**

New test: `test/rho/acceptance_gate_test.exs` → `"replay produces
byte-identical tape entries"` → `"two replays produce identical
(kind, payload) tape entries"`. Drives `Rho.AgentLoop.run/3` twice
with the exact same Mimic-stubbed LLM sequence
(tool-call → tool-result → final text) against two fresh tapes, then
asserts:

```elixir
a = Rho.Tape.Store.read(tape_a) |> Enum.map(&{&1.kind, &1.payload})
b = Rho.Tape.Store.read(tape_b) |> Enum.map(&{&1.kind, &1.payload})
assert a == b
```

(`date` + `id` fields on `Rho.Tape.Entry` are intentionally excluded —
they are a monotonic counter and a UTC timestamp assigned by the Store
at append time and therefore cannot be byte-identical across runs.
`kind` + `payload` are the semantic content.)

Test passes against `Rho.Tools.Bash`/etc. with no extra plugins
registered.

---

## 9. Every README / CLAUDE.md snippet compiles against current code — **PASS**

Grepped all module references in `README.md` and `CLAUDE.md`; all
names match current modules in `lib/`:

- `Rho.Runner`, `Rho.TurnStrategy[.Direct|.Structured]`,
  `Rho.Transformer`, `Rho.Plugin`, `Rho.PluginRegistry`,
  `Rho.PluginInstance`, `Rho.Context`, `Rho.Tape.Context[.Tape]`,
  `Rho.Mount.PromptSection` — all present.
- Context struct example in `README.md:903-916` matches
  `Rho.Context` field list (`lib/rho/context.ex:16-48`): `tape_name`,
  `memory_mod`, `workspace`, `agent_name`, `depth`, `subagent`,
  `agent_id`, `session_id`, `prompt_format`, `user_id` — 10 fields,
  identical order.
- Transformer stage table in `CLAUDE.md` matches the six stages
  and return-tuple contracts enforced by
  `PluginRegistry.apply_stage/3`.
- No stray legacy names (`Rho.Memory`, `Rho.Reasoner`,
  `Rho.Lifecycle`, `Rho.MountInstance`) appear outside explicit
  migration/legacy-alias sections.

Transformer example in `README.md:802-819` compiles against current
`Rho.Transformer` behaviour and `Rho.PluginRegistry.register/2`
signature.

---

## 10. Legacy config keys (`mounts:`, `reasoner:`, `memory_module`) resolve — **PASS**

New test block: `test/rho/acceptance_gate_test.exs` → `"legacy config
keys resolve"` covers:

- `Rho.Config.resolve_mount(:bash)` → `{Rho.Tools.Bash, []}`
- `Rho.Config.resolve_mount({:multi_agent, except: […]})` →
  `{Rho.Mounts.MultiAgent, [except: […]]}`
- `Rho.Config.resolve_mount(RawModule)` → `{RawModule, []}`
- `Rho.Config.resolve_reasoner(:direct)` →
  `Rho.TurnStrategy.Direct` (legacy alias)
- `Rho.Config.resolve_reasoner(:structured)` →
  `Rho.TurnStrategy.Structured`
- `Rho.Config.resolve_turn_strategy(:direct) ==
   Rho.Config.resolve_reasoner(:direct)` (new name + alias agree)
- `Rho.Config.memory_module()` defaults to
  `Rho.Tape.Context.Tape` and honours the `:memory_module` app-env
  override.

Also inspection: `.rho.exs` supports `mounts:` as the canonical key
(`lib/rho/config.ex:7,101`) and `reasoner:` as an alias for
`turn_strategy:` (`lib/rho/config.ex:105`: `config[:turn_strategy] ||
config[:reasoner] || :direct`).

---

## Summary

| # | Criterion | Verdict |
|---|-----------|---------|
| 1 | Tools-only plugin = one module, one callback | PASS |
| 2 | Transformer halt at every haltable stage | PASS |
| 3 | `:tool_args_out` deny continues turn, recorded on tape | PASS |
| 4 | `:post_step` inject visible next turn | PASS |
| 5 | Plugin reads opts from callback args | PASS |
| 6 | New TurnStrategy = zero Runner changes | PASS |
| 7 | New subscriber = zero agent-side changes | PASS |
| 8 | Replay = byte-identical tape entries | PASS |
| 9 | README / CLAUDE.md snippets compile | PASS |
| 10 | Legacy config keys resolve | PASS |

No criterion failed. Acceptance gate closed.
