# Workspace Unification Plan — Critique 2

Second round of review, grounded against the actual codebase.

---

## 1. Signal Matching Is Broken as Written

The plan uses `MapSet.member?` with wildcard patterns:

```elixir
@handled_types MapSet.new([
  "rho.session.*.events.message_sent",
  ...
])

def handles?(type), do: MapSet.member?(@handled_types, type)
```

`MapSet.member?/2` does exact string comparison. The `*` has no special meaning — `"rho.session.abc123.events.message_sent"` will never match `"rho.session.*.events.message_sent"`.

**Fix:** Match on the event suffix. The variable part is the session ID in the middle of the topic (`rho.session.<sid>.events.<event>`), so split on `.events.` and match the suffix:

```elixir
@handled_suffixes MapSet.new(~w(
  message_sent
  broadcast
  text_delta
  assistant_message
))

def handles?(type) when is_binary(type) do
  String.starts_with?(type, "rho.session.") and
    case String.split(type, ".events.", parts: 2) do
      [_prefix, suffix] -> MapSet.member?(@handled_suffixes, suffix)
      _ -> false
    end
end
```

This applies to every projection in the plan: `SpreadsheetProjection`, `ChatroomProjection`, and any future workspace projections.

---

## 2. `read_ws_state/3` Is Fragile and Wasteful

The plan's `SignalRouter.read_ws_state/3` calls `projection.init() |> Map.keys()` on every routed signal to reconstruct the state map from individual assigns:

```elixir
defp read_ws_state(socket, key, projection) do
  projection.init()
  |> Map.keys()
  |> Map.new(fn k -> {k, Map.get(socket.assigns, :"ws_#{key}_#{k}")} end)
end
```

Problems:
- Calls `init/0` on every signal dispatch (wasteful).
- Replaces missing assigns with `nil`, silently losing default values.
- Explodes workspace state into many individual assigns (`ws_spreadsheet_rows_map`, `ws_spreadsheet_next_id`, etc.), making the assign namespace noisy.

**Fix:** Store each workspace's full state as a single assign under a `ws_states` map:

```elixir
# On mount
assign(socket, :ws_states, %{
  spreadsheet: SpreadsheetProjection.init(),
  chatroom: ChatroomProjection.init()
})

# In SignalRouter
defp read_ws_state(socket, key, _projection) do
  get_in(socket.assigns, [:ws_states, key])
end

defp write_ws_state(socket, key, state) do
  update(socket, :ws_states, &Map.put(&1, key, state))
end
```

Pass workspace state to components via `state={@ws_states[@active_workspace_id]}` instead of mirroring many `ws_*_*` assigns.

---

## 3. Signal Metadata Enrichment Is a Hard Prerequisite

The plan assumes signals carry `event_id`, `seq`, and `emitted_at` for deterministic replay. Currently `Rho.Comms.SignalBus.publish/3` only adds:
- `source` (from opts)
- `subject` (optional)
- `correlation_id` / `causation_id` (in extensions, optional)

It does **not** add `event_id`, `seq`, or `emitted_at`.

The `Rho.Agent.EventLog` writes `seq` and `ts` into its JSONL files, but those are not propagated back into live signal payloads. Live subscribers and EventLog replay currently see different shapes.

**Fix:** Add an explicit prerequisite step to the implementation order:

> **Step 0: Signal metadata enrichment**
> - Add `event_id` (UUID) and `emitted_at` (millisecond timestamp) in `Rho.Comms.SignalBus.publish/3`, centrally.
> - Define a normalized signal shape that both live and replay paths produce:
>   ```elixir
>   %{type: ..., data: ..., meta: %{event_id: ..., emitted_at: ..., correlation_id: ..., source: ...}}
>   ```
> - Defer `seq` (monotonic total ordering on the live path) as a separate follow-up unless deterministic ordering across subscribers is immediately required.

Without this, hydration replay and live signal processing cannot use the same reducer path, and the "replayability" guarantee is hollow.

---

## 4. Pure `SessionProjection` Refactor Is Larger Than the Plan Suggests

The plan says "rename existing `SessionProjection`, refactor to pure reducer form." In practice, `SessionProjection` is deeply coupled to LiveView:

| Coupling | Location |
|----------|----------|
| `push_event/3` (sends JS events to client) | `add_signal/3` |
| `Process.send_after/3` (UI spec tick scheduling) | `project_ui_spec/2` |
| `System.unique_integer/1` (message IDs) | `msg_id/0` |
| `System.monotonic_time/1` (timestamps) | `add_signal/3`, `project_before_llm/2` |
| `Rho.Agent.Registry.get/1` (runtime lookup) | agent status updates |
| `Rho.Agent.Registry.find_by_role/2` | message routing |
| Socket assign reads/writes throughout | every `project_*` function |

Making this purely functional in one step is a large refactor with high risk of regressions.

**Fix:** Adjust the plan to either:

**Option A (recommended):** Split into pure state + effects:
- `SessionState.reduce(state, signal) :: state | {state, [effect]}` — pure fold
- `SessionEffects.apply(socket, effects)` — applies `push_event`, `send_after`, registry lookups
- `SignalRouter` calls both: reduce first, then apply effects

**Option B (pragmatic):** Keep `SessionProjection` as a socket-aware adapter during Steps 1–4. Only purify it as a follow-up after workspace projections have proven the pattern. This avoids blocking the unification on the riskiest refactor.

---

## 5. Spreadsheet PID Registration Will Break

`SpreadsheetLive.subscribe_and_hydrate/2` calls `Rho.Stdlib.Plugins.Spreadsheet.register(session_id, self())` to register its PID in an ETS-backed registry (`:rho_spreadsheet_registry`). The spreadsheet plugin's tools use this registry to send synchronous `{:spreadsheet_get_table, ...}` messages for read operations.

Deleting `SpreadsheetLive` without moving this registration breaks all synchronous spreadsheet tool reads ("Spreadsheet not connected" errors).

**Fix:** Add to the plan:
- Move `Spreadsheet.register/unregister` into the unified `SessionLive`, called during workspace mount/unmount.
- Only register when the `:spreadsheet` workspace is active.
- Consider keying the registry by `{:spreadsheet, session_id}` instead of just `session_id`, to support future workspaces that need similar synchronous read patterns.

---

## 6. Spreadsheet Row IDs Are Locally Generated

`SpreadsheetLive.assign_ids/2` increments a local `next_id` counter to assign IDs to incoming rows. The published `spreadsheet_rows_delta` events from `Rho.Stdlib.Plugins.Spreadsheet` do **not** include row IDs — they contain raw row data and the LiveView assigns IDs on receipt.

This means:
- Different subscribers assign different IDs to the same rows.
- Replay from tape produces different IDs than the original live session.
- Step 6's event-sourced edits by `row_id` target IDs that only exist in one subscriber's local state.

**Fix:** Call this out as a prerequisite for Step 6 (event-sourced user edits):
- Generate stable row IDs at publish time in the spreadsheet plugin.
- Include them in `rows_delta` event payloads.
- Projections use the provided IDs instead of generating their own.

This is not needed for Steps 1–4 (where row IDs remain local), but must be resolved before multi-user editing can work.

---

## 7. `assistant_message` Event Does Not Exist

The `ChatroomProjection` in the plan handles an `"assistant_message"` signal type. The current codebase does not publish this event. Final assistant text arrives via `turn_finished` in `SessionProjection`.

Additionally, the current session UI handles both `.text_delta` and `.llm_text` for streaming — chatroom should handle both unless upstream is normalized first.

**Fix:** Use currently published event types in the chatroom projection:
- Replace `"assistant_message"` with `"turn_finished"` (or whatever carries the final text).
- Handle both `"text_delta"` and `"llm_text"` for streaming.
- Only introduce new event types if existing signals are genuinely insufficient for chatroom rendering.

---

## Updated Implementation Order

Incorporating the prerequisites surfaced above:

| Step | What | Notes |
|------|------|-------|
| **0** | **Signal metadata enrichment** | Add `event_id` + `emitted_at` to `Comms.publish/3`. Prerequisite for replay. |
| 1 | Extract `SessionCore` | As planned. Move spreadsheet registration into this step. |
| 2 | Extract projections as pure reducers | `SpreadsheetProjection` and `ChatroomProjection` only. Keep `SessionProjection` as socket-aware adapter for now. Use suffix matching, single `ws_states` assign. |
| 3 | Unify into single `SessionLive` | As planned, with spreadsheet registration in workspace mount lifecycle. |
| 4 | Add `ChatroomProjection` + chatroom workspace | Use existing signal types (`turn_finished`, `text_delta`, `llm_text`). Validates abstraction. |
| 5 | Formalize `Workspace` behaviour (if needed) | As planned. |
| 5.5 | **Purify `SessionProjection`** | Split into `SessionState.reduce/2` + `SessionEffects.apply/3`. Now safe because workspace projections have proven the pattern. |
| 6 | Event-sourced user edits | Prerequisite: stable row IDs from publisher. Then `client_op_id` + last-write-wins. |

---

## Summary of Changes to the Plan

| Issue | Severity | When to fix |
|-------|----------|-------------|
| Signal matching uses fake wildcards | Bug | Before implementing any projection |
| `read_ws_state` per-key explosion | Design flaw | Step 2–3 (use single `ws_states` map) |
| Missing signal metadata | Blocker for replay | Step 0 (new prerequisite) |
| `SessionProjection` purity understated | Risk | Defer to Step 5.5 (after workspace projections prove pattern) |
| Spreadsheet PID registration lost | Bug on delete | Step 1–3 (move registration) |
| Row IDs are local-only | Blocker for Step 6 | Before event-sourced edits |
| `assistant_message` doesn't exist | Bug | Step 4 (use `turn_finished`) |
