# Workspace Unification Plan

## Problem

`SessionLive` and `SpreadsheetLive` duplicate ~60% of their code: session lifecycle, signal subscription, chat state management, message sending, UI stream handling, avatar loading. Adding a new workspace (canvas, code editor, document viewer) means copying all of this again.

## Core Insight

Both LiveViews are the same thing: **an agent session with a chat panel**. The only difference is what artifact sits next to the chat.

The fundamental model:

```
Signal Stream (tape / bus)
    |
    +---> SessionProjection        -> agent status, tokens, per-agent messages (always on)
    +---> ChatroomProjection       -> all agent messages interleaved -> chatroom component
    +---> SpreadsheetProjection    -> rows / groups -> spreadsheet component
    +---> CanvasProjection         -> objects / layout -> canvas component (future)
```

A **workspace** = a pure reducer + a LiveComponent renderer. The LiveView's job is: subscribe to signals, route each signal to the right reducer(s), apply returned state to assigns, render components.

**Chat is not a workspace.** It is always-on shell UI (collapsible side panel) that coexists with any artifact workspace. The `SessionProjection` (base reducer) handles agent status, token counters, streaming state, and per-agent message history regardless of which workspace is active.

---

## Architecture

### Key Concepts

| Concept | What it is |
|---------|-----------|
| **Signal stream** | Append-only shared state (tape + bus) |
| **Projection** | A pure fold: `reduce(state, signal) -> state` |
| **Workspace** | A projection + a LiveComponent renderer (artifact tabs) |
| **Chat side panel** | Cross-cutting shell UI, always available, not a workspace |
| **SessionProjection** | Base reducer (always on): agent status, tokens, per-agent messages |
| **Agent** | A signal producer (doesn't know about workspaces) |
| **User edit** | Also a signal producer (indistinguishable from agent signals) |
| **Multi-user** | Multiple LiveView processes subscribing to the same signal stream |

### Module Structure

```
apps/rho_web/lib/rho_web/
  live/
    session_live.ex              # Single LiveView for all session types
  session/
    session_core.ex              # Session lifecycle (subscribe, hydrate, teardown)
    signal_router.ex             # Routes signals to reducers, applies state to socket
  projections/
    projection.ex                # Behaviour: handles?/1, init/0, reduce/2
    session_projection.ex        # Base: agent status, tokens, messages (socket-aware adapter until Step 5.5)
    chatroom_projection.ex       # Session-scoped interleaved multi-agent timeline (pure)
    spreadsheet_projection.ex    # Rows, groups, cell updates (pure)
  workspaces/
    chat_component.ex            # Chat side panel LiveComponent (shell UI, not a workspace)
    chatroom_component.ex        # Multi-agent chatroom LiveComponent
    spreadsheet_component.ex     # Spreadsheet table + inline editing LiveComponent
  components/
    chat_components.ex           # Existing chat feed/input components, unchanged
    workspace_components.ex      # Workspace tab bar, layout shell
```

---

## Detailed Design

### Projections Are Pure Reducers

Workspace projections (`SpreadsheetProjection`, `ChatroomProjection`, and future ones) are pure functions that fold signals into plain maps. They do not touch `Socket.t()` — the LiveView owns the socket and applies reducer output to assigns.

All rendered item identity and timestamps must come from signal metadata, never from runtime calls inside the reducer. This guarantees:
- Testability (no LiveView dependency)
- Replayability (same signals produce same state)
- Multi-subscriber consistency (all processes derive identical state)

**Note:** `SessionProjection` is an exception during Steps 1–4. It remains a socket-aware adapter because it is deeply coupled to LiveView side effects (`push_event/3`, `Process.send_after/3`, registry lookups). It is purified in Step 5.5 after workspace projections have proven the pattern. See "SessionProjection Purity" section below.

```elixir
defmodule RhoWeb.Projection do
  @moduledoc """
  Behaviour for signal projections. A projection is a pure fold
  from signals into renderable state.
  """

  @doc "Return true if this projection handles the given signal type."
  @callback handles?(signal_type :: String.t()) :: boolean()

  @doc "Return the initial state for this projection."
  @callback init() :: map()

  @doc """
  Fold a signal into state. Must be pure — no side effects, no runtime calls.
  May return plain state or state + effects list for projections that
  need side effects (see SessionProjection).
  """
  @callback reduce(state :: map(), signal :: map()) :: map() | {map(), [effect]}
end
```

### Signal Matching Uses Suffix Extraction

Signal types contain a variable session ID in the middle (e.g., `rho.session.<sid>.events.<event>`). `MapSet.member?/2` does exact string comparison, so wildcard patterns like `"rho.session.*.events.foo"` would never match an actual signal type.

**Fix:** Match on the event suffix after splitting on `.events.`:

```elixir
@handled_suffixes MapSet.new(~w(
  spreadsheet_rows_delta
  spreadsheet_replace_all
  spreadsheet_update_cells
  spreadsheet_delete_rows
  structured_partial
))

def handles?(type) when is_binary(type) do
  String.starts_with?(type, "rho.session.") and
    case String.split(type, ".events.", parts: 2) do
      [_prefix, suffix] -> MapSet.member?(@handled_suffixes, suffix)
      _ -> false
    end
end
```

This pattern applies to every projection in the plan.

### Workspace State Is a Single Assign

Instead of exploding workspace state into many individual assigns (`ws_spreadsheet_rows_map`, `ws_spreadsheet_next_id`, etc.), store all workspace projection state under a single `ws_states` map assign:

```elixir
# On mount
assign(socket, :ws_states, %{
  spreadsheet: SpreadsheetProjection.init(),
  chatroom: ChatroomProjection.init()
})

# In SignalRouter — read/write is a simple map lookup
defp read_ws_state(socket, key) do
  get_in(socket.assigns, [:ws_states, key])
end

defp write_ws_state(socket, key, state) do
  update(socket, :ws_states, &Map.put(&1, key, state))
end
```

Components receive their state as a single prop: `state={@ws_states[@active_workspace_id]}`.

Benefits:
- No `init/0` called on every signal dispatch
- No risk of `nil` replacing default values from missing assigns
- Clean assign namespace
- Components receive a coherent state map, not scattered assigns

### Signal Metadata Requirements

Every signal published through `Rho.Comms.publish/3` must carry stable metadata so projections can derive identity and ordering without runtime calls.

**Current state:** `Rho.Comms.SignalBus.publish/3` only adds `source`, `subject`, and optional `correlation_id`/`causation_id` in extensions. It does **not** add `event_id`, `seq`, or `emitted_at`. The `Rho.Agent.EventLog` writes `seq` and `ts` into its JSONL files, but those are not propagated into live signal payloads. Live subscribers and EventLog replay currently see different shapes.

**Required enrichment (Step 0):**

| Field | Source | Purpose |
|-------|--------|---------|
| `event_id` | UUID generated in `Comms.publish/3` | Stable identity for rendered items |
| `emitted_at` | `System.system_time(:millisecond)` in `Comms.publish/3` | Display timestamps |
| `source` | Already exists in publish opts | Attribution |

These fields are added centrally in `Comms.publish/3` so all signals carry them automatically.

**Deferred:** `seq` (monotonic total ordering) is deferred unless deterministic ordering across subscribers is immediately required.

**Normalized signal shape** for both live and replay paths:

```elixir
%{
  type: "rho.session.xxx.events.message_sent",
  data: %{...},  # event-specific payload
  meta: %{
    event_id: "uuid-here",
    emitted_at: 1717000000000,
    correlation_id: "...",
    source: "/session/xxx/agent/yyy"
  }
}
```

Projections use `meta.event_id` for message IDs instead of `System.unique_integer/1`.

### Assign Naming Convention

Rename ambiguous assigns before unification to prevent confusion:

| Current | Renamed | Why |
|---------|---------|-----|
| `active_tab` | `active_agent_id` | It selects an agent, not a UI tab |
| `tab_order` | `agent_tab_order` | Clarifies these are agent tabs |
| `active_workspace_tab` | `active_workspace_id` | Consistent naming |

For workspace-specific state, use the single `ws_states` map (see above). Workspace reducers may only read/write their own key within this map.

### SessionProjection Purity

The existing `SessionProjection` is deeply coupled to LiveView:

| Coupling | Location |
|----------|----------|
| `push_event/3` (sends JS events to client) | `add_signal/3` |
| `Process.send_after/3` (UI spec tick scheduling) | `project_ui_spec/2` |
| `System.unique_integer/1` (message IDs) | `msg_id/0` |
| `System.monotonic_time/1` (timestamps) | `add_signal/3`, `project_before_llm/2` |
| `Rho.Agent.Registry.get/1` (runtime lookup) | agent status updates |
| Socket assign reads/writes throughout | every `project_*` function |

Making this purely functional in one step is a large refactor with high regression risk. The plan uses a staged approach:

**Steps 1–4:** Keep `SessionProjection` as a socket-aware adapter. It continues to work as today — receives socket, returns socket. Workspace projections (`SpreadsheetProjection`, `ChatroomProjection`) are pure from the start.

**Step 5.5:** After workspace projections have proven the pure reducer pattern, split `SessionProjection` into:
- `SessionState.reduce(state, signal) :: state | {state, [effect]}` — pure fold
- `SessionEffects.apply(socket, effects)` — applies `push_event`, `send_after`, registry lookups

The `SignalRouter` calls both: reduce first, then apply effects. This keeps the pure/impure boundary explicit.

### Spreadsheet PID Registration

`SpreadsheetLive.subscribe_and_hydrate/2` calls `Rho.Stdlib.Plugins.Spreadsheet.register(session_id, self())` to register its PID in an ETS-backed registry. The spreadsheet plugin's tools use this registry to send synchronous `{:spreadsheet_get_table, ...}` messages for read operations.

Deleting `SpreadsheetLive` without moving this registration breaks all synchronous spreadsheet tool reads ("Spreadsheet not connected" errors).

**Fix:** Move `Spreadsheet.register/unregister` into the unified `SessionLive`:
- Register during workspace mount when `:spreadsheet` workspace is active
- Unregister in `terminate/2`
- Handle `{:spreadsheet_get_table, ...}` messages in `SessionLive.handle_info/2`

### Spreadsheet Row IDs

`SpreadsheetLive.assign_ids/2` increments a local `next_id` counter to assign IDs to incoming rows. The published `spreadsheet_rows_delta` events do **not** include row IDs — they contain raw row data and the LiveView assigns IDs on receipt.

This means:
- Different subscribers assign different IDs to the same rows
- Replay from tape produces different IDs than the original live session
- Event-sourced edits by `row_id` target IDs that only exist in one subscriber's local state

**For Steps 1–4:** This is acceptable. Row IDs remain local, same as today.

**Prerequisite for Step 6 (event-sourced edits):** Generate stable row IDs at publish time in the spreadsheet plugin. Include them in `rows_delta` event payloads. Projections use the provided IDs instead of generating their own.

---

## Step 0: Signal Metadata Enrichment

**Prerequisite for all subsequent steps.** Without this, hydration replay and live signal processing cannot use the same reducer path, and the "replayability" guarantee is hollow.

Changes to `Rho.Comms.SignalBus.publish/3`:
1. Generate a UUID `event_id` for every published signal
2. Add `emitted_at` timestamp (milliseconds)
3. Attach both in a `meta` map on the signal, alongside existing `correlation_id` and `source`
4. Ensure the normalized shape `%{type, data, meta}` is what both live subscribers and tape replay produce

**Scope:** Small change to one module (`Rho.Comms.SignalBus`), but touches every signal in the system. Verify no downstream code breaks from the added fields.

---

## Step 1: Extract SessionCore

Pull shared session lifecycle out of both LiveViews into a plain module.

**`RhoWeb.Session.SessionCore`** owns:
- Session ID validation
- `subscribe_and_hydrate/2` — subscribe to signal bus topics, hydrate agent list, set common assigns. Includes spreadsheet PID registration when `:spreadsheet` workspace is active.
- `unsubscribe/1` — clean up subscriptions + spreadsheet unregistration
- `ensure_session/2` — create session if needed (with agent_name option for spreadsheet-style sessions)
- Common assigns initialization (agents, agent_tab_order, active_agent_id, inflight, pending_response, token counters, avatars)
- Avatar loading helpers
- Message sending logic (session creation, target resolution, user message append)
- UI stream tick handling

```elixir
defmodule RhoWeb.Session.SessionCore do
  @doc "Initialize all common session assigns on a socket."
  def init(socket, opts \\ []) do
    socket
    |> assign(:session_id, nil)
    |> assign(:agents, %{})
    |> assign(:active_agent_id, nil)
    |> assign(:agent_tab_order, [])
    |> assign(:inflight, %{})
    |> assign(:agent_messages, %{})
    |> assign(:ui_streams, %{})
    |> assign(:pending_response, MapSet.new())
    |> assign(:total_input_tokens, 0)
    |> assign(:total_output_tokens, 0)
    |> assign(:total_cost, 0.0)
    |> assign(:total_cached_tokens, 0)
    |> assign(:total_reasoning_tokens, 0)
    |> assign(:step_input_tokens, 0)
    |> assign(:step_output_tokens, 0)
    |> assign(:connected, false)
    |> assign(:user_avatar, load_avatar("avatar"))
    |> assign(:agent_avatar, load_agent_avatar(opts))
  end

  def subscribe_and_hydrate(socket, session_id, opts \\ []) do
    # Ensure session exists (with optional agent_name for spreadsheet etc.)
    # Subscribe to signal bus topics
    # Hydrate agent list from Registry
    # Set agent_tab_order, active_agent_id, agent_messages
    # If :spreadsheet in active workspaces, register PID
    # Returns updated socket
  end

  def unsubscribe(socket) do
    # Unsubscribe from all bus_subs
    # Unregister spreadsheet PID if registered
  end

  def validate_session_id(nil), do: nil
  def validate_session_id(sid) do
    case Rho.Agent.Primary.validate_session_id(sid) do
      :ok -> sid
      {:error, _} -> nil
    end
  end

  def send_message(socket, content, opts \\ []) do
    # Shared message submission logic
    # Handles session creation, target resolution, user message append
    # Returns {:noreply, socket}
  end

  def handle_ui_spec_tick(socket, message_id) do
    # Shared UI stream tick handling
  end
end
```

Both LiveViews call into it during this step. No behaviour change from user perspective. Existing tests still pass.

---

## Step 2: Extract Projections as Pure Reducers

Extract `SpreadsheetProjection` as a pure reducer. Keep `SessionProjection` as a socket-aware adapter for now (see "SessionProjection Purity" above).

### SpreadsheetProjection (extract from SpreadsheetLive)

Move `handle_rows_delta`, `handle_replace_all`, `handle_update_cells`, `handle_delete_rows`, `handle_structured_partial` and all helpers (JSON extraction, row grouping, ID assignment) into a pure reducer operating on plain maps.

```elixir
defmodule RhoWeb.Projections.SpreadsheetProjection do
  @behaviour RhoWeb.Projection

  @handled_suffixes MapSet.new(~w(
    spreadsheet_rows_delta
    spreadsheet_replace_all
    spreadsheet_update_cells
    spreadsheet_delete_rows
    structured_partial
  ))

  def init do
    %{
      rows_map: %{},
      next_id: 1,
      partial_streamed: %{}
    }
  end

  def handles?(type) when is_binary(type) do
    String.starts_with?(type, "rho.session.") and
      case String.split(type, ".events.", parts: 2) do
        [_prefix, suffix] -> MapSet.member?(@handled_suffixes, suffix)
        _ -> false
      end
  end

  def reduce(state, %{type: type, data: data}) do
    case extract_suffix(type) do
      "spreadsheet_rows_delta" -> reduce_rows_delta(state, data)
      "spreadsheet_replace_all" -> reduce_replace_all(state)
      "spreadsheet_update_cells" -> reduce_update_cells(state, data)
      "spreadsheet_delete_rows" -> reduce_delete_rows(state, data)
      "structured_partial" -> reduce_structured_partial(state, data)
      _ -> state
    end
  end

  defp extract_suffix(type) do
    case String.split(type, ".events.", parts: 2) do
      [_, suffix] -> suffix
      _ -> nil
    end
  end

  # All private helpers moved here from SpreadsheetLive,
  # rewritten to operate on plain maps instead of sockets.
end
```

### Testing projections

Pure reducers are trivially testable:

```elixir
test "rows_delta appends rows" do
  state = SpreadsheetProjection.init()
  signal = %{
    type: "rho.session.test.events.spreadsheet_rows_delta",
    data: %{rows: [%{"skill_name" => "Elixir"}]},
    meta: %{event_id: "evt-1", emitted_at: 1717000000000}
  }
  new_state = SpreadsheetProjection.reduce(state, signal)
  assert map_size(new_state.rows_map) == 1
end

test "replay produces identical state" do
  signals = [signal_1, signal_2, signal_3]
  state_a = Enum.reduce(signals, SpreadsheetProjection.init(), &SpreadsheetProjection.reduce(&2, &1))
  state_b = Enum.reduce(signals, SpreadsheetProjection.init(), &SpreadsheetProjection.reduce(&2, &1))
  assert state_a == state_b
end
```

---

## Step 3: Unify Into Single SessionLive With Simple Workspace Registry

No formal behaviour yet. Use a plain registry map.

### Key UX constraint: workspace switching must not remount

Routes suggest the *initial* workspace set, but switching workspace tabs is an assign change within the same LiveView process. All workspace projections run continuously regardless of which tab is visible. Switching tabs is instant — no remount, no replay, no lost state (scroll position, inline edits, streaming context all preserved).

This is achieved by:
1. `mount/3` sets initial workspaces from `live_action`
2. `handle_params/3` keeps the process alive on URL changes (session switches only)
3. `switch_workspace` event changes `active_workspace_id` assign — no navigation
4. Users can dynamically add workspace tabs via a "+" picker button
5. All routes for the same session share the same `SessionLive` module, so `live_action` changes within the same session use `handle_params`, not a new mount

```elixir
defmodule RhoWeb.SessionLive do
  use Phoenix.LiveView

  alias RhoWeb.Session.{SessionCore, SignalRouter}

  # Plain map — no behaviour until chatroom validates the API
  @workspace_registry %{
    spreadsheet: %{
      label: "Skills Editor",
      icon: "table",
      component: RhoWeb.Workspaces.SpreadsheetComponent,
      projection: RhoWeb.Projections.SpreadsheetProjection
    }
  }

  @impl true
  def mount(params, _session, socket) do
    session_id = SessionCore.validate_session_id(params["session_id"])

    # Route suggests initial workspaces, but user can add/remove later
    initial_keys = determine_initial_workspaces(socket.assigns.live_action)
    workspaces = Map.take(@workspace_registry, initial_keys)

    # Initialize common session state
    socket = SessionCore.init(socket)

    # Initialize workspace projection states as a single assign
    ws_states =
      Map.new(workspaces, fn {key, ws} -> {key, ws.projection.init()} end)

    socket =
      socket
      |> assign(:workspaces, workspaces)
      |> assign(:ws_states, ws_states)
      |> assign(:active_workspace_id, List.first(initial_keys))
      |> assign(:chat_visible, should_show_chat?(initial_keys))

    socket =
      if connected?(socket) && session_id do
        socket
        |> SessionCore.subscribe_and_hydrate(session_id,
          agent_name: agent_name_for(socket.assigns.live_action),
          active_workspaces: Map.keys(workspaces)
        )
        |> hydrate_workspaces(session_id)
      else
        socket
      end

    {:ok, socket}
  end

  # handle_params keeps the process alive on URL changes.
  # Switching between /editor/sid and /chatroom/sid does NOT remount —
  # it just updates the active workspace tab.
  @impl true
  def handle_params(%{"session_id" => sid}, _uri, socket) do
    cond do
      # Different session — full resubscribe
      socket.assigns.session_id != sid && connected?(socket) ->
        socket = SessionCore.unsubscribe(socket)
        socket = assign(socket, :session_id, sid)
        socket = SessionCore.subscribe_and_hydrate(socket, sid)
        socket = hydrate_workspaces(socket, sid)
        {:noreply, socket}

      # Same session, possibly different live_action — just ensure
      # the workspace for this route exists in the tab set
      true ->
        route_keys = determine_initial_workspaces(socket.assigns.live_action)
        socket = ensure_workspaces_open(socket, route_keys)
        # Switch to the first workspace from this route
        active = List.first(route_keys) || socket.assigns.active_workspace_id
        {:noreply, assign(socket, :active_workspace_id, active)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    SessionCore.unsubscribe(socket)
    :ok
  end

  # Route suggests initial workspaces — user can add more dynamically
  defp determine_initial_workspaces(:chat), do: []
  defp determine_initial_workspaces(:spreadsheet), do: [:spreadsheet]
  defp determine_initial_workspaces(:chatroom), do: [:chatroom]
  defp determine_initial_workspaces(:full), do: [:spreadsheet, :chatroom]
  defp determine_initial_workspaces(_), do: []

  defp should_show_chat?(keys) do
    # Show chat side panel when there are artifact workspaces
    # (when no workspaces, chat is the main content)
    keys != []
  end

  defp agent_name_for(:spreadsheet), do: :spreadsheet
  defp agent_name_for(:editor), do: :spreadsheet
  defp agent_name_for(:full), do: :spreadsheet
  defp agent_name_for(_), do: nil

  # Ensure workspace tabs exist without removing existing ones.
  # Called from handle_params when live_action changes within same session.
  defp ensure_workspaces_open(socket, keys) do
    current = socket.assigns.workspaces
    missing = Enum.reject(keys, &Map.has_key?(current, &1))

    if missing == [] do
      socket
    else
      new_ws = Map.take(@workspace_registry, missing)
      new_states = Map.new(new_ws, fn {k, ws} -> {k, ws.projection.init()} end)

      socket
      |> update(:workspaces, &Map.merge(&1, new_ws))
      |> update(:ws_states, &Map.merge(&1, new_states))
      |> hydrate_workspaces_for(socket.assigns.session_id, missing)
    end
  end

  # --- Events ---

  @impl true
  def handle_event("send_message", params, socket) do
    SessionCore.send_message(socket, params)
  end

  def handle_event("select_agent_tab", %{"agent-id" => agent_id}, socket) do
    {:noreply, assign(socket, :active_agent_id, agent_id)}
  end

  # Tab switching — just an assign change, no navigation, no remount
  def handle_event("switch_workspace", %{"workspace" => ws}, socket) do
    {:noreply, assign(socket, :active_workspace_id, String.to_existing_atom(ws))}
  end

  def handle_event("toggle_chat", _params, socket) do
    {:noreply, assign(socket, :chat_visible, !socket.assigns.chat_visible)}
  end

  # Dynamically add a workspace tab at runtime
  def handle_event("add_workspace", %{"workspace" => ws}, socket) do
    key = String.to_existing_atom(ws)

    if Map.has_key?(socket.assigns.workspaces, key) do
      # Already open — just switch to it
      {:noreply, assign(socket, :active_workspace_id, key)}
    else
      case Map.get(@workspace_registry, key) do
        nil ->
          {:noreply, socket}

        ws_def ->
          socket =
            socket
            |> update(:workspaces, &Map.put(&1, key, ws_def))
            |> update(:ws_states, &Map.put(&1, key, ws_def.projection.init()))
            |> assign(:active_workspace_id, key)

          # Hydrate from tape if session exists
          socket =
            if socket.assigns.session_id do
              hydrate_workspaces_for(socket, socket.assigns.session_id, [key])
            else
              socket
            end

          {:noreply, socket}
      end
    end
  end

  # Remove a workspace tab
  def handle_event("close_workspace", %{"workspace" => ws}, socket) do
    key = String.to_existing_atom(ws)

    socket =
      socket
      |> update(:workspaces, &Map.delete(&1, key))
      |> update(:ws_states, &Map.delete(&1, key))

    # If we closed the active tab, switch to another
    socket =
      if socket.assigns.active_workspace_id == key do
        next = socket.assigns.workspaces |> Map.keys() |> List.first()
        assign(socket, :active_workspace_id, next)
      else
        socket
      end

    {:noreply, socket}
  end

  # Workspace-specific events are handled by the LiveComponent directly

  # --- Signal handling ---

  @impl true
  def handle_info({:signal, %Jido.Signal{type: type, data: data} = signal}, socket) do
    sid = socket.assigns.session_id

    if signal_for_session?(data, sid) do
      correlation_id = get_in(signal.extensions || %{}, ["correlation_id"])

      normalized = %{
        type: type,
        data: data,
        meta: %{
          event_id: signal.id,
          emitted_at: get_in(signal.extensions || %{}, ["emitted_at"]),
          correlation_id: correlation_id,
          source: signal.source
        }
      }

      {:noreply, SignalRouter.route(socket, normalized)}
    else
      {:noreply, socket}
    end
  end

  # Spreadsheet tool synchronous reads
  def handle_info({:spreadsheet_get_table, {caller_pid, ref}, filter}, socket) do
    rows =
      get_in(socket.assigns, [:ws_states, :spreadsheet, :rows_map])
      |> case do
        nil -> []
        rows_map -> rows_map |> Map.values() |> filter_rows(filter)
      end

    send(caller_pid, {ref, {:ok, rows}})
    {:noreply, socket}
  end

  def handle_info({:ui_spec_tick, message_id}, socket) do
    {:noreply, SessionCore.handle_ui_spec_tick(socket, message_id)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="session-layout">
      <.workspace_tab_bar
        :if={map_size(@workspaces) > 0 or @chat_visible}
        workspaces={@workspaces}
        active={@active_workspace_id}
        available={available_workspaces(assigns)}
        chat_visible={@chat_visible}
        pending={MapSet.size(@pending_response) > 0}
        total_cost={@total_cost}
      />

      <div class="session-panels">
        <div class="workspace-panel">
          <%= for {key, ws} <- @workspaces do %>
            <div class={"workspace-content #{if key == @active_workspace_id, do: "active", else: "hidden"}"}>
              <.live_component
                module={ws.component}
                id={"workspace-#{key}"}
                state={@ws_states[key]}
              />
            </div>
          <% end %>
        </div>

        <.chat_side_panel
          :if={show_chat_panel?(assigns)}
          messages={active_messages(assigns)}
          inflight={active_inflight(assigns)}
          session_id={@session_id || ""}
          active_agent_id={@active_agent_id || ""}
          user_avatar={@user_avatar}
          agent_avatar={@agent_avatar}
          pending={MapSet.member?(@pending_response, @active_agent_id || primary_agent_id(@session_id))}
          agents={@agents}
          agent_tab_order={@agent_tab_order}
        />
      </div>
    </div>
    """
  end

  # Smart chat panel visibility:
  # - Hidden when chatroom is the active workspace (redundant)
  # - Shown otherwise when chat_visible is true
  # - Full width when no workspaces are open
  defp show_chat_panel?(assigns) do
    assigns.chat_visible and assigns.active_workspace_id != :chatroom
  end

  # Available workspaces that aren't already open (for "+" picker)
  defp available_workspaces(assigns) do
    open_keys = Map.keys(assigns.workspaces)
    @workspace_registry
    |> Enum.reject(fn {key, _} -> key in open_keys end)
    |> Map.new()
  end

  # --- Hydration ---

  defp hydrate_workspaces(socket, session_id) do
    # Replay tape through the same reducers used for live updates.
    # This ensures late joiners and reconnects see the same state
    # as live subscribers.
    tape_signals = load_session_tape(session_id)

    ws_states =
      Map.new(socket.assigns.workspaces, fn {key, ws} ->
        state =
          tape_signals
          |> Enum.filter(fn s -> ws.projection.handles?(s.type) end)
          |> Enum.reduce(ws.projection.init(), fn s, st -> ws.projection.reduce(st, s) end)

        {key, state}
      end)

    assign(socket, :ws_states, ws_states)
  end

  # Hydrate only specific workspace keys (for dynamically added tabs)
  defp hydrate_workspaces_for(socket, nil, _keys), do: socket
  defp hydrate_workspaces_for(socket, session_id, keys) do
    tape_signals = load_session_tape(session_id)
    workspaces = socket.assigns.workspaces

    new_states =
      keys
      |> Enum.filter(&Map.has_key?(workspaces, &1))
      |> Map.new(fn key ->
        ws = workspaces[key]
        state =
          tape_signals
          |> Enum.filter(fn s -> ws.projection.handles?(s.type) end)
          |> Enum.reduce(ws.projection.init(), fn s, st -> ws.projection.reduce(st, s) end)

        {key, state}
      end)

    update(socket, :ws_states, &Map.merge(&1, new_states))
  end
end
```

### Signal Router

All workspace projections run continuously regardless of which tab is visible. The signal router iterates over all entries in `workspaces`, not just the active one. Rendering cost for hidden workspaces is zero (`:if` or `hidden` class). Projection cost is negligible (2–4 reducer calls per signal).

```elixir
defmodule RhoWeb.Session.SignalRouter do
  @doc """
  Route a signal through the base SessionProjection (socket-aware adapter),
  then through every active workspace's pure projection (not just the visible one).
  """
  def route(socket, signal) do
    # Always run base session projection (socket-aware adapter for now)
    socket = apply_session_projection(socket, signal)

    # Route to ALL workspace projections, not just the visible one.
    # This ensures hidden workspaces stay up-to-date for instant tab switching.
    ws_states = socket.assigns.ws_states

    updated_states =
      Enum.reduce(socket.assigns.workspaces, ws_states, fn {key, ws}, states ->
        if ws.projection.handles?(signal.type) do
          state = Map.fetch!(states, key)
          new_state = ws.projection.reduce(state, signal)
          Map.put(states, key, new_state)
        else
          states
        end
      end)

    assign(socket, :ws_states, updated_states)
  end
end
```

### Router Changes

All routes map to the same `SessionLive` module. Navigating between routes for the same session uses `handle_params` (same process, no remount). Only the initial workspace set differs.

```elixir
# Before
live "/chat", SessionLive
live "/chat/:session_id", SessionLive
live "/editor", SpreadsheetLive
live "/editor/:session_id", SpreadsheetLive

# After — all use SessionLive, live_action suggests initial workspaces
live "/chat", SessionLive, :chat
live "/chat/:session_id", SessionLive, :chat
live "/editor", SessionLive, :spreadsheet
live "/editor/:session_id", SessionLive, :spreadsheet
live "/chatroom", SessionLive, :chatroom
live "/chatroom/:session_id", SessionLive, :chatroom
live "/full", SessionLive, :full
live "/full/:session_id", SessionLive, :full
```

Delete `SpreadsheetLive`.

---

## Step 4: Add ChatroomProjection + Chatroom Workspace

This step validates the abstraction. If the workspace registry + pure reducer model works cleanly for chatroom, the API is proven. If not, adjust before formalizing.

### ChatroomProjection

Projects all inter-agent communication into a single interleaved timeline. Uses signal metadata for identity and timestamps — no runtime calls inside the reducer.

**Important:** Use actually published event types. The codebase does not publish an `assistant_message` event. Final assistant text arrives via `turn_finished` in `SessionProjection`. Streaming uses both `text_delta` and `llm_text`.

```elixir
defmodule RhoWeb.Projections.ChatroomProjection do
  @behaviour RhoWeb.Projection

  @handled_suffixes MapSet.new(~w(
    message_sent
    broadcast
    text_delta
    llm_text
    turn_finished
  ))

  def init do
    %{
      messages: [],
      streaming: %{}
    }
  end

  def handles?(type) when is_binary(type) do
    String.starts_with?(type, "rho.session.") and
      case String.split(type, ".events.", parts: 2) do
        [_prefix, suffix] -> MapSet.member?(@handled_suffixes, suffix)
        _ -> false
      end
  end

  def reduce(state, %{type: type, data: data, meta: meta}) do
    case extract_suffix(type) do
      "message_sent" ->
        append(state, %{
          id: meta.event_id,
          from: data.from,
          to: data.to,
          content: data.message,
          kind: :direct,
          timestamp: meta.emitted_at
        })

      "broadcast" ->
        append(state, %{
          id: meta.event_id,
          from: data.from,
          to: :all,
          content: data.message,
          kind: :broadcast,
          timestamp: meta.emitted_at
        })

      suffix when suffix in ~w(text_delta llm_text) ->
        update_streaming(state, data[:agent_id], data[:content] || data[:text])

      "turn_finished" ->
        agent_id = data[:agent_id]
        state = flush_streaming(state, agent_id)

        # Extract final text from turn_finished data if present
        case data[:content] || data[:result] do
          nil -> state
          content ->
            append(state, %{
              id: meta.event_id,
              from: agent_id,
              to: nil,
              content: content,
              kind: :response,
              timestamp: meta.emitted_at
            })
        end

      _ ->
        state
    end
  end

  defp extract_suffix(type) do
    case String.split(type, ".events.", parts: 2) do
      [_, suffix] -> suffix
      _ -> nil
    end
  end

  defp append(state, msg), do: %{state | messages: state.messages ++ [msg]}

  defp update_streaming(state, nil, _content), do: state
  defp update_streaming(state, agent_id, content) do
    %{state | streaming: Map.update(state.streaming, agent_id, content || "", &(&1 <> (content || "")))}
  end

  defp flush_streaming(state, nil), do: state
  defp flush_streaming(state, agent_id) do
    %{state | streaming: Map.delete(state.streaming, agent_id)}
  end
end
```

### Add to workspace registry

```elixir
@workspace_registry %{
  spreadsheet: %{
    label: "Skills Editor",
    icon: "table",
    component: RhoWeb.Workspaces.SpreadsheetComponent,
    projection: RhoWeb.Projections.SpreadsheetProjection
  },
  chatroom: %{
    label: "Chatroom",
    icon: "users",
    component: RhoWeb.Workspaces.ChatroomComponent,
    projection: RhoWeb.Projections.ChatroomProjection
  }
}
```

No session code changes. No signal bus changes.

### Multi-agent signal compatibility

The existing `Rho.Stdlib.Plugins.MultiAgent` already publishes all necessary signals:

| Agent tool call | Published signal | Chatroom shows |
|---|---|---|
| `send_message(target: "B", message: "...")` | `events.message_sent` with `from`, `to`, `message` | "A -> B: ..." |
| `broadcast_message(message: "...")` | `events.broadcast` with `from`, `message` | "A (to all): ..." |
| Agent streams a response | `events.text_delta` / `events.llm_text` with `agent_id` | Streaming indicator |
| Agent completes turn | `events.turn_finished` with `agent_id` | "A: ..." |

No changes needed to the multi-agent plugin.

### User input in chatroom mode

| User action | Resolved to |
|---|---|
| Type message, no @mention | `Worker.submit(primary_pid, content)` — primary agent decides routing |
| Type `@researcher check this` | Resolve "researcher" via `Registry.find_by_role`, submit to that agent |
| Type `@agent_id_123 do X` | Direct `Worker.submit(target_pid, "do X")` |

The user's message is also published as a signal so it appears in the chatroom timeline.

### Chatroom rendering

Each message shows:
- **Speaker**: agent role + colored avatar (consistent color per agent_id)
- **Direction indicator**: `->` for direct, `(to all)` for broadcast, nothing for responses
- **Target**: who the message was addressed to (for direct messages)
- **Content**: the message text
- **Streaming**: animated indicator when an agent is mid-response

---

## Step 5: Formalize Workspace Behaviour (If Needed)

Only after chatroom has validated the API. If the plain registry map works cleanly for both spreadsheet and chatroom, formalize:

```elixir
defmodule RhoWeb.Workspace do
  @callback id() :: atom()
  @callback label() :: String.t()
  @callback icon() :: String.t()
  @callback component() :: module()
  @callback projection() :: module()  # Must implement RhoWeb.Projection
end
```

This is deliberately thin — just metadata pointing to a component and a projection. The projection behaviour is separate and already defined. No signal routing, no socket manipulation in the workspace contract.

If the plain map is still sufficient after chatroom, skip this step entirely. Formalize only if:
- 4+ workspace types exist
- Workspace definitions must be discoverable at runtime (plugins)
- Type safety across the registry is causing bugs

---

## Step 5.5: Purify SessionProjection

After workspace projections have proven the pure reducer pattern, split `SessionProjection`:

**`SessionState`** — pure reducer:
```elixir
defmodule RhoWeb.Projections.SessionState do
  @behaviour RhoWeb.Projection

  def reduce(state, signal) do
    # Pure fold — returns state or {state, effects}
    # Effects are descriptors, not actions:
    #   {:push_event, name, payload}
    #   {:send_after, delay, message}
    #   {:registry_lookup, agent_id}
    {new_state, effects}
  end
end
```

**`SessionEffects`** — impure effect applicator:
```elixir
defmodule RhoWeb.Session.SessionEffects do
  def apply(socket, effects) do
    Enum.reduce(effects, socket, fn
      {:push_event, name, payload} -> push_event(socket, name, payload)
      {:send_after, delay, msg} -> (Process.send_after(self(), msg, delay); socket)
      {:registry_lookup, agent_id} -> # ...
    end)
  end
end
```

The `SignalRouter` calls both: `SessionState.reduce/2` first, then `SessionEffects.apply/2`.

---

## Step 6: Event-Sourced User Edits

Last step. Only after the core unification is stable.

### Prerequisites (must be resolved before this step)

1. **Stable row IDs from publisher:** Generate row IDs in the spreadsheet plugin at publish time, not in the LiveView on receipt. Include them in `rows_delta` event payloads so all subscribers and replay paths see the same IDs.

2. **Durable signal writes:** `Rho.Comms.publish/3` must write to durable tape, not just transient PubSub. Otherwise hydration replay won't have the user edit signals.

### What event sourcing actually gives you

- Shared visibility for edits across subscribers
- Replayability (if tape is durable and reducers are pure)
- Auditability (who changed what, when)

### What it does NOT give you for free

- Undo (requires reverse operations or snapshots)
- Conflict resolution (requires explicit policy)
- Optimistic reconciliation (requires `client_op_id`)

### Implementation

Every user edit signal must include a `client_op_id` for optimistic reconciliation:

```elixir
def handle_event("save_edit", %{"row_id" => id, "field" => field, "value" => value}, socket) do
  sid = socket.assigns.session_id
  client_op_id = "op_#{System.unique_integer([:positive])}"

  # 1. Optimistic: apply locally for instant feedback
  socket = apply_optimistic_edit(socket, id, field, value, client_op_id)

  # 2. Publish for other subscribers and durability
  Rho.Comms.publish(
    "rho.session.#{sid}.events.spreadsheet_update_cells",
    %{
      session_id: sid,
      client_op_id: client_op_id,
      changes: [%{id: id, field: field, value: value}]
    },
    source: "/user/#{socket.assigns.current_user.id}"
  )

  {:noreply, socket}
end
```

When the echoed signal arrives via `handle_info`, the reducer checks `client_op_id`:
- If it matches a pending optimistic op, skip (already applied).
- If it doesn't match, apply normally (another user's edit).

### Conflict policy

Start with **last-write-wins at cell level**. Each cell update carries `emitted_at` from signal metadata. If two users edit the same cell, the later timestamp wins.

---

## UI Layout

### Tab bar design

```
+--[Skills Editor]--[Chatroom]--[+]------------------[Chat >]--+
|                                                                |
|  Active workspace                          Chat side panel     |
|  (full width when chat closed)             (30%, collapsible)  |
|                                                                |
+----------------------------------------------------------------+
```

- Workspace tabs on the left side of the tab bar (closeable with x)
- **"+" button** opens a dropdown of available workspaces from `@workspace_registry` that aren't already open. This lets users discover and compose workspace views without knowing URLs.
- Chat toggle on the right side (with streaming indicator dot)
- Only one artifact workspace visible at a time (tabs are mutually exclusive) — but **all projections run continuously** so switching is instant with no state loss
- Chat side panel slides in/out independently
- When no workspaces are active (`:chat` route), chat takes full width as main content

### Workspace switching behavior

- Clicking a workspace tab: `assign(:active_workspace_id, key)` — no navigation, no remount
- Clicking "+": adds workspace to `workspaces` and `ws_states`, hydrates from tape, switches to it
- Clicking "x" on a tab: removes from `workspaces` and `ws_states`, switches to next tab
- Navigating from `/editor/sid` to `/chatroom/sid`: `handle_params` adds chatroom tab, switches to it. Spreadsheet state preserved.
- All scroll positions, inline edits, streaming context survive tab switches

### Smart chat panel behavior

Reduce confusion between chat side panel (1:1 DMs) and chatroom (group timeline):

| Active workspace | Chat side panel behavior |
|-----------------|--------------------------|
| Spreadsheet (no chatroom tab) | Show side panel with agent DM tabs (current behavior) |
| Chatroom | Auto-hide side panel (redundant — all messages are in the chatroom) |
| Spreadsheet + Chatroom tabs | Side panel available for 1:1 agent DMs; chatroom tab shows group view |
| No workspaces (`:chat` route) | Chat takes full width as main content |

### Agent presence in workspace tabs

```
[Skills Editor . agent-3 streaming...]  [Chatroom]  [+]  [Chat >]
```

A subtle inline indicator shows which agent is actively producing signals for each workspace.

### In-session workspace discovery flow

```
User clicks [+]:
  ┌──────────────────┐
  │ Add workspace:   │
  │  📊 Skills Editor│  ← only shows workspaces not already open
  │  💬 Chatroom     │
  │  🎨 Canvas       │
  └──────────────────┘

User clicks "Chatroom":
  - ChatroomProjection.init() added to ws_states
  - Hydrated from tape replay
  - Tab appears, switches to it
  - Chat side panel auto-hides (chatroom shows messages)
  - No navigation, no remount
```

---

## Step 0.5: UI Snapshot Infrastructure

### Problem

UI state and LLM context are two separate resumption problems:

| | **LLM Context** | **UI State** |
|---|---|---|
| **Source** | `Rho.Tape.Store` (JSONL per agent) | Signal bus (in-memory) + EventLog (filtered) |
| **Consumer** | `Rho.Tape.View` → LLM messages | `SessionLive` → socket assigns |
| **Already works?** | Yes — tape persists, View rebuilds from anchor | No — EventLog filters out `text_delta`/`structured_partial` |
| **Compaction** | `Tape.Compact` exists | No UI snapshots exist |

Full signal replay is neither feasible (EventLog filters high-frequency signals) nor desirable (slow for long sessions). Instead, persist a snapshot of workspace projection state — the UI analog of a tape anchor.

### Snapshot Module

```elixir
defmodule RhoWeb.Session.Snapshot do
  @filename "ui_snapshot.json"

  def save(session_id, workspace, state) do
    dir = Path.join([workspace, "_rho", "sessions", session_id])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, @filename), Jason.encode!(state))
  end

  def load(session_id, workspace) do
    path = Path.join([workspace, "_rho", "sessions", session_id, @filename])
    case File.read(path) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, :enoent} -> :none
    end
  end
end
```

### What to snapshot

| Include | Exclude |
|---------|---------|
| `ws_states` (all workspace projection state) | Streaming state (ephemeral) |
| Session projection state (agents, messages, tokens) | `pending_response`, `inflight` (process-specific) |
| `active_workspace_id`, workspace keys, `chat_visible` | PID references, upload state |
| `agent_tab_order`, `active_agent_id` | |
| Snapshot timestamp | |

Serialization: `MapSet` → list for JSON, reconstruct on load. Atom keys → string keys, reconstruct with `String.to_existing_atom/1`.

### Snapshot lifecycle

**Save:** On `terminate/2` (browser close, navigation away). Optionally periodically (every N signals).

**Load:** On `mount/3`, before subscribing to live signals:

```elixir
socket =
  if connected?(socket) && session_id do
    case Snapshot.load(session_id, workspace) do
      {:ok, snapshot} ->
        socket
        |> apply_snapshot(snapshot)
        |> SessionCore.subscribe_and_hydrate(session_id, ...)
        |> apply_signals_since(session_id, snapshot["timestamp"])

      :none ->
        socket
        |> init_fresh_workspaces(workspace_keys)
        |> SessionCore.subscribe_and_hydrate(session_id, ...)
    end
  else
    init_fresh_workspaces(socket, workspace_keys)
  end
```

### Tail replay (catch-up after snapshot)

Between the snapshot timestamp and "now", signals may have been emitted (agent kept running while browser was closed). Sources in preference order:

1. **Signal bus replay** (`Rho.Comms.replay/2` with `since: timestamp`) — if same BEAM instance
2. **EventLog replay** — if bus is gone but EventLog is alive (note: `text_delta`/`structured_partial` are filtered out, but final state signals are captured)
3. **Nothing** — snapshot is the best we have (may be slightly stale)

### Background LLM compaction on resume

When a session is resumed after a long gap, the agent tape may have grown large. Compact before the next LLM call, not on UI load:

```elixir
# In SessionCore.subscribe_and_hydrate — don't block mount
if Rho.Tape.Compact.needed?(tape_name) do
  Task.start(fn -> Rho.Tape.Compact.run(tape_name, model: default_model()) end)
end
```

The user sees their UI instantly (from snapshot). Compaction happens in the background.

### What "resume" looks like to the user

1. User opens `/editor/session-123`
2. **Instant** (< 100ms): Snapshot loads. Spreadsheet shows rows, chat shows messages.
3. **Fast** (< 500ms): Tail replay applies any signals since the snapshot.
4. **Background**: Agent tape compacted if needed. Agent ready for next message.
5. User types a message → agent responds with full context.

**Degraded flow** (no snapshot): workspace starts empty, agent has full context from tape, new actions rebuild UI from live signals. Acceptable as fallback.

---

## Step 3.5: Conversation Threads

### Problem

Users want to explore different approaches without losing their current conversation. "Let me try a different skill taxonomy — but keep this one in case I want to come back."

### What already exists

| Component | Status |
|-----------|--------|
| `Rho.Tape.Fork.fork/2` | Exists — creates new tape from a fork point |
| `Rho.Tape.Fork.merge/2` | Exists — appends fork delta back to main tape |
| `Rho.Tape.Fork.fork_info/1` | Exists — returns fork metadata |
| `Rho.Tape.Context.fork/2` | Exists — optional callback in behaviour |
| `Rho.Tape.Service.handoff/4` | Exists — creates anchor with summary |
| `Rho.Tape.Compact.run/2` | Exists — summarizes history into anchor |
| UI for listing/selecting threads | **Missing** |
| Thread metadata storage | **Missing** |
| Agent tape_ref hot-swapping | **Missing** |

### Data model: Thread = named tape + metadata

```elixir
%{
  id: "thread_abc123",
  name: "Category-first approach",
  tape_name: "session_xxx_fork_1",
  session_id: "session-123",
  created_at: "2026-04-06T14:30:00Z",
  forked_from: "thread_main",     # parent thread id
  fork_point: 42,                 # entry ID in parent tape
  summary: "Trying category-first instead of skill-first organization",
  status: "active"
}
```

### Thread registry

Simple JSON file per session:

```
_rho/sessions/{session_id}/
  events.jsonl          # existing EventLog
  ui_snapshot.json      # from Step 0.5 (becomes per-thread in snapshots/ dir)
  threads.json          # thread metadata + active_thread_id
  snapshots/
    thread_main.json
    thread_abc123.json
```

```elixir
defmodule Rho.Session.Threads do
  def list(session_id, workspace)
  def active(session_id, workspace)
  def create(session_id, workspace, attrs)
  def switch(session_id, workspace, thread_id)
end
```

### Compact before fork (hard requirement)

When forking, the new tape starts with a `fork_origin` anchor. The anchor's summary is all the LLM context the agent has for pre-fork history. Without compaction, the agent has amnesia.

```elixir
def fork_thread(session_id, workspace, opts) do
  current_tape = current_tape_name(session_id, workspace)
  fork_point = opts[:at] || Store.last_id(current_tape)

  # 1. Summarize conversation up to fork point (LLM call)
  summary = summarize_up_to(current_tape, fork_point, opts)

  # 2. Create fork with enriched anchor
  fork_name = "#{current_tape}_fork_#{:erlang.unique_integer([:positive])}"
  Service.append(fork_name, :anchor, %{
    "name" => "fork_origin",
    "state" => %{"summary" => summary},
    "fork" => %{"source_tape" => current_tape, "at_id" => fork_point}
  })

  {:ok, fork_name}
end
```

**When to skip compaction:**
- Fork point is at entry 1–5 (barely any history) — just copy entries
- Recent anchor exists near the fork point — reuse its summary
- User explicitly says "start fresh" — empty summary

### Agent tape switching

**Option A (recommended to start): Restart agent**

```elixir
def switch_thread(socket, thread) do
  Rho.Agent.Primary.stop(socket.assigns.session_id)
  Rho.Agent.Primary.ensure_started(socket.assigns.session_id,
    tape_ref: thread["tape_name"]
  )
  SessionCore.subscribe_and_hydrate(socket, socket.assigns.session_id)
end
```

Simple, correct, clean state. Brief delay (< 500ms). Move to hot-swap only if restart delay is noticeable.

**Option B (future): Hot-swap via message**

```elixir
# In Worker — only swap when idle, queue if mid-turn
def handle_cast({:swap_tape, new_tape_ref}, state) do
  if state.status == :idle do
    {:noreply, %{state | tape_ref: new_tape_ref}}
  else
    {:noreply, %{state | pending_tape_swap: new_tape_ref}}
  end
end
```

### Thread-aware snapshots

Each thread gets its own snapshot. Switching threads saves the current thread's snapshot and loads the target's:

```elixir
def handle_event("switch_thread", %{"thread_id" => thread_id}, socket) do
  sid = socket.assigns.session_id

  # 1. Save current thread's snapshot
  save_snapshot(sid, workspace, socket.assigns.active_thread_id, build_snapshot(socket))

  # 2. Switch active thread + restart agent with new tape
  Threads.switch(sid, workspace, thread_id)
  thread = Threads.get(sid, workspace, thread_id)
  switch_agent_tape(socket, thread)

  # 3. Load new thread's snapshot or replay
  socket =
    case load_snapshot(sid, workspace, thread_id) do
      {:ok, snap} -> apply_snapshot(socket, snap)
      :none -> replay_workspace_state(socket, thread["tape_name"])
    end

  {:noreply, assign(socket, :active_thread_id, thread_id)}
end
```

### Thread picker UI

Hidden for single-thread sessions (zero overhead). Appears when branching occurs:

```
┌─ Chat ─────────────────────────┐
│ Thread: Category-first ▾       │  ← thread picker in chat header
│ ┌─────────────────────────┐    │
│ │ ● Category-first        │    │  ← active (dot)
│ │   Main                  │    │
│ │   ──────────────────    │    │
│ │   ⑂ Fork from here      │    │
│ │   + New blank thread    │    │
│ └─────────────────────────┘    │
│ [agent tabs]                   │
│ [messages...]                  │
│ [input]                        │
└────────────────────────────────┘
```

Thread summary preview on hover (from tape's latest anchor):

```
┌─────────────────────────────────────┐
│ ● Category-first approach           │
│   "Exploring organizing skills by   │
│    category first, then by level."  │
│   Created: 2h ago · 24 messages     │
└─────────────────────────────────────┘
```

### User flows

1. **New session**: Thread "Main" created implicitly. No thread UI visible.
2. **Fork**: User clicks "Fork" → names it → compact + fork + switch. Thread picker appears.
3. **Switch threads**: Save snapshot, switch tape, load snapshot. Instant.
4. **Fork from past message**: Right-click message → "Fork from here" → fork at that entry ID.
5. **Resume with threads**: Load `threads.json`, restore active thread, load its snapshot.

---

## Hydration: One Code Path for Live and Reconnect

Late joiners and reconnecting clients must see the same state as live subscribers. The hydration strategy is layered:

### Layer 1: Snapshot (instant)

Load the UI snapshot from disk. User sees their session immediately.

### Layer 2: Tail replay (catch-up)

Replay signals emitted since the snapshot through the same `reduce/2` functions:

```elixir
def hydrate_workspace(socket, key, projection, session_id) do
  # Prefer snapshot + tail replay
  case Snapshot.load(session_id, workspace) do
    {:ok, snap} ->
      state = snap.ws_states[key] || projection.init()
      tail_signals = load_signals_since(session_id, snap.timestamp)

      state =
        tail_signals
        |> Enum.filter(fn s -> projection.handles?(s.type) end)
        |> Enum.reduce(state, fn s, st -> projection.reduce(st, s) end)

      update(socket, :ws_states, &Map.put(&1, key, state))

    :none ->
      # No snapshot — full replay from EventLog (may be incomplete for streaming signals)
      tape_signals = load_session_tape(session_id)
      state =
        tape_signals
        |> Enum.filter(fn s -> projection.handles?(s.type) end)
        |> Enum.reduce(projection.init(), fn s, st -> projection.reduce(st, s) end)

      update(socket, :ws_states, &Map.put(&1, key, state))
  end
end
```

### Layer 3: Background LLM compaction

If the agent tape is large, compact in background before the agent's next LLM call. Does not block UI.

### Guarantees

- No divergence between live and hydrated state (same reducers)
- No separate "load from database" code path that can drift
- Snapshot + tail is fast even for long sessions
- Graceful degradation if snapshot is missing (full replay, possibly incomplete)

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Replay drift from non-deterministic projections | Require stable event metadata on every signal; no runtime calls in reducers |
| Over-broad workspace contract | Keep workspace metadata thin; keep reducers as separate behaviour |
| Assign name confusion | Rename `active_tab` -> `active_agent_id` etc. before unification |
| Hydration gaps for late joiners | Replay tape through same reducers used for live updates |
| Double-apply on optimistic updates | `client_op_id` + reconciliation in reducer |
| Hidden render cost from inactive workspaces | Only render the active workspace component (`hidden` class); projections still run |
| Premature behaviour formalization | Defer behaviour until chatroom validates the API |
| SessionProjection regression during purification | Defer to Step 5.5; use effects descriptor pattern |
| Spreadsheet PID registration lost on delete | Move registration into SessionCore lifecycle |
| Local row IDs diverge across subscribers | Acceptable for Steps 1-4; generate stable IDs at publisher for Step 6 |
| Chatroom uses nonexistent event types | Use `turn_finished`, `text_delta`, `llm_text` (actually published types) |
| Route change kills workspace state | Workspace selection is an assign, not a route. `handle_params` keeps process alive |
| Chat panel vs chatroom confusion | Smart auto-hide: chat panel hidden when chatroom is active workspace |
| No workspace discovery in-session | "+" picker button in tab bar shows available workspaces |
| Snapshot serialization failures | Ensure all projection state is JSON-serializable (no PIDs, refs, functions) |
| Stale snapshot after long gap | Tail replay catches up; graceful degradation if replay source unavailable |
| Thread switch loses in-flight work | Start with agent restart (Option A); queue-based hot-swap as future optimization |
| Fork without compaction = agent amnesia | Hard requirement: compact before fork to generate summary for fork anchor |

---

## When to Revisit

Move to a more complex design only if:
- 4+ workspace types exist and the plain registry map becomes unwieldy
- Workspace definitions must be plugin/discoverable at runtime
- Signal volume makes naive routing measurably slow
- Full replay is too slow and per-workspace snapshots with periodic checkpointing are needed
- Workspaces need independent write-side authorization
- Per-workspace threads are needed (currently per-session)

---

## Adding a New Workspace (Checklist)

1. Create `RhoWeb.Projections.MyProjection` — implement `RhoWeb.Projection` behaviour (`handles?/1`, `init/0`, `reduce/2`) using suffix matching
2. Create `RhoWeb.Workspaces.MyComponent` — LiveComponent that receives `state` prop
3. Add entry to `@workspace_registry` in `SessionLive`
4. (Optional) Add route: `live "/my-view/:session_id", SessionLive, :my_view` + `determine_initial_workspaces(:my_view)` clause — only needed if you want a dedicated URL that opens this workspace by default
5. Write replay-style tests for the projection

The new workspace is automatically discoverable via the "+" picker in the tab bar. Users can add it to any session at runtime without a dedicated route.

No session code changes. No chat code changes. No signal bus changes.

---

## Implementation Order Summary

| Step | What | Validates |
|------|------|-----------|
| **0** | Signal metadata enrichment (`event_id` + `emitted_at` in `Comms.publish/3`) | Prerequisite for deterministic replay |
| **0.5** | UI snapshot infrastructure (`Snapshot.save/load`, serialize/deserialize) | UI state survives browser close |
| 1 | Extract `SessionCore` (includes spreadsheet PID registration) | Shared lifecycle works as plain module |
| 2 | Extract `SpreadsheetProjection` as pure reducer (suffix matching, plain maps) | Reducers are testable and replayable |
| 3 | Unify into one `SessionLive` with plain workspace registry + single `ws_states` assign + snapshot save/load | Registry map + signal routing + resumption works |
| **3.5** | Conversation threads (thread registry, picker UI, fork with compaction, agent tape restart) | Users can branch and switch conversations |
| 4 | Add `ChatroomProjection` + chatroom workspace (using actual event types) | Abstraction works for a second workspace |
| 5 | Formalize `Workspace` behaviour (if needed) | Only if registry map proves insufficient |
| 5.5 | Purify `SessionProjection` (split into `SessionState` + `SessionEffects`) | Pure/impure boundary explicit |
| 6 | Event-sourced user edits (prereq: stable row IDs from publisher, durable signals) | Multi-user editing with conflict resolution |
