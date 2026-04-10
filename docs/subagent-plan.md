> **Superseded.** `Rho.Plugins.Subagent.Worker` and `.Supervisor` have been
> absorbed into `Rho.Agent.Worker` and `Rho.Agent.Supervisor`. Multi-agent
> coordination now lives in `Rho.Mounts.MultiAgent`. See CLAUDE.md.

# Subagent Plugin Implementation Plan

## Overview

Implement subagents as a self-contained plugin (`Rho.Plugins.Subagent`) that allows an agent to spawn child agents with separate context windows, run them asynchronously, and collect their results. Includes CLI UI for progress visualization.

## Architecture

```
Parent AgentLoop (tape: main_tape)
  │
  ├─ LLM calls `spawn_subagent` tool
  │     ├─ Fork tape from main_tape (child inherits context summary)
  │     ├─ Spawn Task under Rho.TaskSupervisor
  │     │     └─ AgentLoop.run(model, [user(task)], tape_name: fork_tape, subagent: true)
  │     └─ Return subagent_id immediately
  │
  ├─ LLM continues working / spawns more subagents
  │
  ├─ after_tool_call hook piggybacks completion notifications
  │
  └─ LLM calls `collect_subagent` tool
        ├─ Task.yield (blocks until done or timeout)
        ├─ Optionally merge fork tape back to parent tape
        └─ Return subagent's final text response
```

### Tape Fork Chain (nested subagents)

```
main_tape
  └─ main_tape_fork_1001 (subagent A, depth 1)
  │    └─ main_tape_fork_1001_fork_1003 (A's child, depth 2)
  └─ main_tape_fork_1002 (subagent B, depth 1)
```

---

## Files to Create

### 1. `lib/rho/plugins/subagent.ex` — Main plugin

The plugin implements `Rho.HookSpec` and uses two hooks:
- `provide_tools/1` — injects `spawn_subagent` and `collect_subagent` tools
- `after_tool_call/1` — piggybacks completion notifications onto tool results

#### State tracking

Use an ETS table (`:rho_subagents`) to track running subagents:

```elixir
# Key: subagent_id (string)
# Value: %{
#   task: Task.t(),           # Task.Supervisor reference
#   fork_tape: String.t(),    # forked tape name
#   parent_tape: String.t(),  # parent's tape name
#   prompt: String.t(),       # original task prompt (for UI)
#   step: integer,            # current step (updated via on_event)
#   max_steps: integer,       # max steps
#   status: :running | :done | :error
# }
```

#### provide_tools/1

```elixir
def provide_tools(%{tape_name: tape_name, workspace: workspace} = ctx) do
  depth = ctx[:depth] || 0
  if depth >= @max_depth do
    []  # don't offer spawn/collect at max depth
  else
    [spawn_tool(tape_name, workspace, depth), collect_tool()]
  end
end
```

#### spawn_subagent tool

Parameters:
- `task` (string, required) — prompt for the subagent
- `system_prompt` (string, optional) — override system prompt
- `max_steps` (integer, optional, default 30)

Implementation:
1. Check concurrency limit (`@max_concurrent`, default 5)
2. Fork tape from parent: `Rho.Tape.Fork.fork(parent_tape)`
3. Generate subagent_id: `"sub_#{:erlang.unique_integer([:positive])}"`
4. Resolve tools for child (same base toolset, rebound to fork context)
5. Build subagent system prompt with depth info
6. Spawn via `Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn -> ... end)`
7. Pass `on_event` callback that updates ETS with step progress
8. Store in ETS, return subagent_id

Key detail — the `on_event` callback for progress reporting:
```elixir
on_event = fn
  %{type: :step_start, step: step, max_steps: max} ->
    update_progress(subagent_id, step, max)
    :ok
  _ -> :ok
end
```

#### collect_subagent tool

Parameters:
- `subagent_id` (string, required)
- `merge` (boolean, optional, default false) — merge fork tape entries back to parent

Implementation:
1. Look up subagent in ETS
2. `Task.yield(task, 600_000) || Task.shutdown(task)` — wait up to 10 min
3. If `merge: true`, call `Rho.Tape.Fork.merge(fork_tape, parent_tape)`
4. Clean up ETS entry
5. Return subagent's final text result

#### after_tool_call/1

Check for completed subagents whose parent_tape matches the current tape. If any have finished, append a notification to the tool output:

```elixir
def after_tool_call(%{tape_name: tape_name, output: output}) do
  case check_completed(tape_name) do
    [] -> nil  # no override
    done ->
      notice = Enum.map_join(done, "\n", fn {id, result} ->
        "[subagent #{id} finished: #{String.slice(result, 0..300)}]"
      end)
      {:override, output <> "\n\n" <> notice}
  end
end
```

`check_completed/1` uses `Task.yield(task, 0)` (non-blocking) to check each subagent.

#### Subagent system prompt

```elixir
defp subagent_system_prompt(task, depth, max_depth) do
  can_spawn = depth < max_depth
  """
  You are a subagent (depth #{depth}/#{max_depth}). You cannot interact with the user.
  Make reasonable assumptions instead of asking clarifying questions.
  Call the `finish` tool with your final result when your task is complete.

  #{if can_spawn do
    "You may spawn sub-subagents for parallel subtasks."
  else
    "You are at max depth. Do all work directly — do not attempt to spawn subagents."
  end}

  Your task:
  #{task}
  """
end
```

#### Depth gating

- `provide_tools/1` checks `ctx[:depth]` — returns empty list at max depth
- Tools are physically absent from the schema, so LLM can't even try to call them
- System prompt reinforces this as a secondary signal

#### Orphan cleanup

When collecting a subagent, also shut down any of its children:

```elixir
defp shutdown_descendants(subagent_id) do
  # Find children whose parent_tape matches this subagent's fork_tape
  :ets.tab2list(@table)
  |> Enum.filter(fn {_id, info} -> info.parent_subagent == subagent_id end)
  |> Enum.each(fn {child_id, info} ->
    shutdown_descendants(child_id)
    Task.shutdown(info.task, :brutal_kill)
    :ets.delete(@table, child_id)
  end)
end
```

Add `parent_subagent` field to ETS entries to track lineage.

### 2. `lib/rho/tools/finish.ex` — Finish tool

Simple tool that subagents call to signal completion:

```elixir
defmodule Rho.Tools.Finish do
  def tool_def do
    %{
      tool: ReqLLM.tool(
        name: "finish",
        description: "Call this when your task is complete. Pass your final result.",
        parameter_schema: [
          result: [type: :string, required: true, doc: "Your final result to return to the parent"]
        ],
        callback: fn _args -> :ok end
      ),
      execute: fn args ->
        {:ok, args["result"] || args[:result] || "done"}
      end
    }
  end
end
```

### 3. `lib/rho/plugins/subagent/ui.ex` — CLI progress display

Renders a live-updating status box for active subagents using ANSI escape codes.

```
  ┌ subagents ─────────────────────────────────────┐
  │ sub_1  refactor auth module  ██████░░░░  6/30  │
  │ sub_2  update auth tests     ████░░░░░░  4/30  │
  └────────────────────────────────────────────────┘
```

#### Implementation

```elixir
defmodule Rho.Plugins.Subagent.UI do
  @box_width 54

  def render_status(subagents) do
    if subagents == [], do: return

    lines = Enum.map(subagents, fn {id, info} ->
      label = info.prompt
        |> String.slice(0..22)
        |> String.pad_trailing(23)
      bar = progress_bar(info.step, info.max_steps)
      step_str = "#{info.step}/#{info.max_steps}" |> String.pad_leading(7)
      "  │ #{id}  #{label} #{bar} #{step_str} │"
    end)

    box = [
      "  ┌ subagents #{String.duplicate("─", @box_width - 14)}┐",
      lines,
      "  └#{String.duplicate("─", @box_width)}┘"
    ] |> List.flatten() |> Enum.join("\n")

    # Move cursor up to overwrite previous render
    up = "\e[#{length(lines) + 2}A\r"
    IO.write(up <> box <> "\n")
  end

  def initial_render(subagents) do
    # First render — no cursor movement needed
    # ... same box without the up escape
  end

  def clear(line_count) do
    # Clear the status box when all subagents are collected
    up = "\e[#{line_count}A\r"
    blank = String.duplicate(" ", @box_width + 4)
    IO.write(up <> Enum.map_join(1..line_count, "\n", fn _ -> blank end) <> "\e[#{line_count}A\r")
  end

  defp progress_bar(step, max) when max > 0 do
    filled = round(step / max * 10)
    String.duplicate("█", filled) <> String.duplicate("░", 10 - filled)
  end

  defp progress_bar(_, _), do: "░░░░░░░░░░"
end
```

#### Integration with the plugin

The `on_event` callback passed to each subagent's `AgentLoop.run` updates ETS and triggers a redraw:

```elixir
on_event = fn
  %{type: :step_start, step: step, max_steps: max} ->
    :ets.update_element(@table, subagent_id,
      [{@step_pos, step}, {@max_steps_pos, max}])
    active = active_subagents_for(parent_tape)
    Rho.Plugins.Subagent.UI.render_status(active)
    :ok
  _ -> :ok
end
```

The first `spawn_subagent` call does `initial_render/1`. Subsequent step events use `render_status/1` (with cursor-up). When `collect_subagent` is called and no active subagents remain, `clear/1` removes the box.

---

## Files to Modify

### 4. `lib/rho/agent_loop.ex` — Subagent loop mode

Add `subagent: true` option support. Two changes:

#### a. Thread `depth` through hook_context (line ~37)

```elixir
hook_context = %{
  model: model,
  tape_name: tape_name,
  messages: messages,
  opts: opts,
  workspace: opts[:workspace],
  agent_name: opts[:agent_name],
  depth: opts[:depth] || 0          # <-- add this
}
```

This allows `provide_tools/1` to see the depth and gate subagent tools accordingly.

#### b. Handle text-without-tool-calls in subagent mode (line ~180)

Current behavior: returns `{:ok, text}` — loop ends.

New behavior when `loop_opts.subagent == true`:
- Check if the `finish` tool was called this step → if yes, return its result
- Otherwise, inject a system nudge to continue working, and loop again

```elixir
case tool_calls do
  [] ->
    text = ReqLLM.Response.text(response)

    if loop_opts[:subagent] do
      # Subagent emitted text without calling finish — nudge to continue
      if loop_opts.tape_name do
        Rho.Tape.Service.append(loop_opts.tape_name, :message, %{
          "role" => "assistant", "content" => text
        })
        Rho.Tape.Service.append(loop_opts.tape_name, :message, %{
          "role" => "user",
          "content" => "[System] Continue working on your task. Call `finish` with your result when done."
        })
      end

      updated_context =
        if loop_opts.tape_name do
          view = Rho.Tape.View.default(loop_opts.tape_name)
          [ReqLLM.Context.system(loop_opts.system_prompt) | Rho.Tape.View.to_messages(view)]
        else
          nudge = ReqLLM.Context.user("[System] Continue working. Call `finish` when done.")
          context ++ [ReqLLM.Context.assistant(text), nudge]
        end

      do_loop(model, updated_context, req_tools, tool_defs, gen_opts, loop_opts,
        step: step + 1, max_steps: max)
    else
      # Normal mode — return text as final response
      if loop_opts.tape_name && text do
        Rho.Tape.Service.append(loop_opts.tape_name, :message, %{
          "role" => "assistant", "content" => text
        })
      end
      {:ok, text}
    end
```

#### c. Detect `finish` tool call as termination signal (line ~254)

Currently checks for `create_anchor`. Add `finish` check:

```elixir
anchor_called? = Enum.any?(tool_calls, fn tc -> ReqLLM.ToolCall.name(tc) == "create_anchor" end)
finish_called? = Enum.any?(tool_calls, fn tc -> ReqLLM.ToolCall.name(tc) == "finish" end)

cond do
  anchor_called? ->
    {:ok, response_text}

  finish_called? ->
    # Extract the finish tool's result
    finish_result = Enum.find_value(tool_calls, fn tc ->
      if ReqLLM.ToolCall.name(tc) == "finish" do
        args = ReqLLM.ToolCall.args_map(tc) || %{}
        args["result"] || response_text
      end
    end)
    {:ok, finish_result}

  true ->
    # Continue looping...
end
```

#### d. Add `subagent` and `depth` to loop_opts (line ~99)

```elixir
loop_opts = %{
  on_event: on_event,
  tape_name: tape_name,
  system_prompt: system_prompt,
  on_text: on_text,
  compact_threshold: opts[:compact_threshold],
  plugin_states: plugin_states,
  subagent: opts[:subagent] || false,     # <-- add
  depth: opts[:depth] || 0                 # <-- add
}
```

### 5. `lib/rho/session/worker.ex` — Pass depth to hook_context

In `handle_call({:message, ...})`, add depth to hook_context:

```elixir
hook_context = Map.put(tool_context, :agent_name, state.agent_name)
               |> Map.put(:depth, opts[:depth] || 0)
```

This is only relevant for subagent spawns — the top-level session worker always has depth 0.

### 6. `.rho.exs` — Register the plugin

```elixir
%{
  default: [
    plugins: [Rho.Plugins.Subagent],
    tools: [:bash, :fs_read, :fs_write, :fs_edit, :anchor]
    # spawn_subagent and collect_subagent are injected by the plugin via provide_tools
  ]
}
```

---

## Constants / Configuration

| Constant | Default | Location | Notes |
|----------|---------|----------|-------|
| `@max_depth` | 3 | Plugin | Max nesting depth (0 = parent, 3 = great-grandchild) |
| `@max_concurrent` | 5 | Plugin | Global concurrent subagent limit |
| `@collect_timeout` | 600_000 | Plugin | 10 min timeout for collect_subagent |
| `@default_max_steps` | 30 | Plugin | Default max_steps for subagents |

These could later be made configurable via `.rho.exs` agent config.

---

## Notification Flow

When a subagent completes while the parent is still in its agent loop:

1. Subagent's `AgentLoop.run` returns `{:ok, result}` (via `finish` tool)
2. The Task completes — `Task.yield/2` will now return immediately
3. Next time the parent calls any tool, `after_tool_call` hook fires
4. Hook calls `check_completed(parent_tape)` — non-blocking `Task.yield(task, 0)`
5. Completed subagent result is appended to the tool's output string
6. LLM sees `"[subagent sub_1 finished: ...]"` and can decide to collect or continue

When the parent is idle (returned to user):
- Subagent completion sends a message through the channel system (future enhancement)
- For v1: user sees the status box showing completion, and can prompt the agent to collect

---

## Testing Plan

### Unit tests: `test/rho/plugins/subagent_test.exs`

1. **Spawn and collect** — spawn a subagent with a simple task, collect result
2. **Depth gating** — at max_depth, `provide_tools` returns empty list
3. **Concurrency limit** — spawning beyond `@max_concurrent` returns error
4. **Finish tool** — subagent loop continues until `finish` is called
5. **Subagent nudge** — text-without-finish in subagent mode triggers continuation
6. **Fork tape isolation** — subagent writes don't appear in parent tape
7. **Merge** — `collect_subagent(merge: true)` merges fork entries to parent
8. **Orphan cleanup** — collecting parent shuts down descendants
9. **Nested spawn** — subagent spawns its own child (depth 2)
10. **Timeout** — subagent that exceeds timeout returns error message

### Integration test: `test/rho/plugins/subagent_integration_test.exs`

1. Full round-trip: parent agent spawns two subagents, collects both, synthesizes result
2. Requires a mock LLM or a cheap model to avoid API costs

### UI test: `test/rho/plugins/subagent/ui_test.exs`

1. `render_status/1` produces correct ANSI output
2. `progress_bar/2` edge cases (0/0, 30/30, etc.)
3. `clear/1` produces correct escape sequences

---

## Implementation Order

1. **`lib/rho/tools/finish.ex`** — standalone, no dependencies
2. **`lib/rho/agent_loop.ex` changes** — subagent mode + finish detection
3. **`lib/rho/plugins/subagent.ex`** — core plugin with spawn/collect/hooks
4. **Tests for 1-3** — verify core behavior works
5. **`lib/rho/plugins/subagent/ui.ex`** — progress display
6. **Wire up UI** — integrate on_event callbacks with UI renderer
7. **`.rho.exs`** — register plugin
8. **Manual testing** — end-to-end with real LLM

---

## Future Enhancements (not in v1)

- **Channel-based wakeup**: subagent completion sends a message through `Channel.Manager` to wake idle parent sessions
- **Configurable toolsets**: allow `spawn_subagent` to specify which tools the child gets (e.g. read-only subagent)
- **Cost tracking**: aggregate token usage across subagent tree
- **Subagent profiles**: use different agent configs (model, system prompt) from `.rho.exs` for subagents
- **Interactive subagents**: route subagent questions to user via channel system (multi-agent chat UX)
- **Web UI panels**: collapsible panels per subagent in web channel
