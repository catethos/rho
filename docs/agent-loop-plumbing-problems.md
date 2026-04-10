> **Superseded.** These problems are resolved. The agent loop is now
> `Rho.Runner` + `Rho.TurnStrategy`, with a single `Rho.Context` struct
> and `Rho.Transformer` pipeline. See CLAUDE.md.

# Agent Loop Plumbing Problems

## 1. Three Redundant Context Maps

The agent loop constructs three maps that overlap heavily. The same data is copied, nested, and re-extracted at each boundary.

```
hook_context (built in run)
├── model          ─┬─► also in loop_opts ─┬─► also in reasoner_context
├── tape_name       │                       │
├── memory_mod      │                       │
├── depth           │                       │
├── workspace       │                       │
├── agent_name      │                       │
├── messages        │                       │
└── opts            │                       │
                    │                       │
loop_opts           │                       │
├── model          ◄┘                       │
├── tape_name      ◄┘                       │
├── memory_mod     ◄┘                       │
├── depth          ◄┘                       │
├── hook_context   (nested copy of above)   │
├── emit                                    │
├── system_prompt                           │
├── compact_threshold                       │
├── subagent                                │
├── reasoner                                │
├── gen_opts                                │
├── tool_defs                               │
└── req_tools                               │
                                            │
reasoner_context (rebuilt each step)        │
├── model          ◄────────────────────────┘
├── tape_name      ◄────────────────────────┘
├── memory_mod     ◄────────────────────────┘
├── emit           ◄────────────────────────┘
├── hook_context   (nested copy, again)
├── subagent       ◄────────────────────────┘
├── gen_opts       ◄────────────────────────┘
├── step           (new — only exists here)
└── max_steps      (new — only exists here)
```

`model` appears in all three. `tape_name` and `memory_mod` appear in all three. `hook_context` is nested inside both `loop_opts` and `reasoner_context`, carrying duplicates of the fields that already exist one level up.

`run_reasoner/4` (agent_loop.ex:166–181) exists solely to unpack 7 fields from `loop_opts`, add `step` and `max_steps`, repack them into `reasoner_context`, and pass it along. It's a map-reshuffling function that does no work.

## 2. hook_context Is an Undefined Contract

`hook_context` is a bare map with no struct, no type, and no documentation of what fields are required. It is:

- Built in `run` (agent_loop.ex:40–49)
- Nested inside `loop_opts` without explanation
- Extracted from `loop_opts` at four dispatch sites
- Passed to all `MountRegistry.dispatch_*` functions
- Passed through to `Reasoner.Direct`, which extracts it to pass to the same dispatch functions

The only field MountRegistry actually uses from it is `:agent_name` (for scope filtering). But the hook_context carries 8 fields because individual mount implementations *might* read any of them. There's no way to know which mounts need which fields without reading every mount.

## 3. The Reasoner Reaches Back Into MountRegistry

`Reasoner.Direct` directly calls `MountRegistry.dispatch_before_tool/2` (line 101) and `MountRegistry.dispatch_after_tool/3` (line 144). This means:

- The reasoner is coupled to a specific hook dispatch mechanism
- Testing the reasoner requires a running MountRegistry GenServer
- A custom reasoner must know to call MountRegistry or hooks silently stop working
- Hook dispatch is split across two modules (`before_llm`/`after_step` in AgentLoop, `before_tool`/`after_tool` in Reasoner.Direct) with no single place showing the full lifecycle

## 4. `run` Conflates Configuration, Initialization, and Side Effects

The `run` function (agent_loop.ex:32–75) does five different things in one block:

1. **Option resolution** — defaults, fallbacks, reading from config (lines 33–38)
2. **Hook context construction** — building the map mounts will receive (lines 40–49)
3. **Prompt assembly** — collecting mount prompt sections, bindings (line 52)
4. **Side effect** — writing user messages to the tape (line 54)
5. **Loop state construction** — building the fat `loop_opts` map (lines 58–72)

These are interleaved: option resolution feeds into hook_context which feeds into prompt assembly which feeds into loop_opts. The linear dependency chain isn't visible because everything is local variables in one function body.

## 5. Helper Names Hide Intent

Several helpers exist to wrap a single dispatch call, but their names describe mechanics, not lifecycle position:

| Function | What the name says | What it actually does |
|----------|-------------------|----------------------|
| `apply_before_llm/2` | "apply something before LLM" | Dispatches the `before_llm` mount hook |
| `collect_injected_messages/3` | "collect some messages" | Runs the `after_step` mount hook |
| `run_reasoner/4` | "run the reasoner" | Reshuffles loop_opts into reasoner_context, then calls the reasoner |
| `maybe_compact/2` | "maybe compact" | Checks token threshold, compacts tape, emits event, rebuilds context |

`collect_injected_messages` is the worst offender — it conceals that `after_step` hooks are being run, making the mount lifecycle invisible when reading `do_loop`.

## 6. `loop_opts` Is a God Map

`loop_opts` has 13 fields serving four different concerns:

| Concern | Fields |
|---------|--------|
| LLM calling | `model`, `gen_opts`, `reasoner` |
| Memory/tape | `tape_name`, `memory_mod`, `system_prompt`, `compact_threshold` |
| Mount hooks | `hook_context`, `subagent` |
| Tools | `tool_defs`, `req_tools` |
| Observability | `emit` |
| Identity | `depth` |

Every helper receives the full map even though each only needs 2–3 fields. `emit_event` needs `tape_name`, `emit`, `memory_mod`. `rebuild_tape_context` needs `system_prompt`, `memory_mod`, `tape_name`. `apply_before_llm` needs `subagent`, `req_tools`, `hook_context`. There's no structure communicating which fields belong to which concern.

## 7. Errors Silently Disappear

`maybe_compact/2` (agent_loop.ex:147) catches `{:error, _}` from `mem.compact_if_needed/2` and returns the original context with no logging, no event emission, and no signal to the caller. A compaction failure is invisible.

## 8. The Reasoner Also Records to Tape

`Reasoner.Direct` calls `memory_mod.append` directly (line 187) to record assistant text to tape. But `AgentLoop.record_tool_step` also records to tape (lines 262–286). Tape recording responsibility is split across two modules with no clear boundary for who records what:

- **Reasoner.Direct** records: assistant text when there are no tool calls (line 187)
- **AgentLoop** records: assistant text when there ARE tool calls (line 267), plus all tool calls and results (lines 270–285), plus user messages (line 96)

The split follows the control flow accidentally rather than by design.
