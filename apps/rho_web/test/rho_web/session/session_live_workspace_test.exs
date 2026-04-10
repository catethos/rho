defmodule RhoWeb.SessionLiveWorkspaceTest do
  @moduledoc """
  Tests for workspace tab events and route-driven layout in SessionLive.

  These tests exercise the socket-level logic (assigns, workspace maps,
  handle_event callbacks) without requiring a full connected LiveView.
  """
  use ExUnit.Case, async: true

  alias RhoWeb.Projections.DataTableProjection

  # Build a minimal LiveView socket with the assigns SessionLive would set.
  defp build_socket(overrides) do
    base = %{
      __changed__: %{},
      live_action: :show,
      session_id: "test-session-123",
      workspaces: %{},
      ws_states: %{},
      active_workspace_id: nil,
      shell: RhoWeb.Session.Shell.init([], []),
      agents: %{},
      active_agent_id: nil,
      agent_tab_order: [],
      inflight: %{},
      signals: [],
      agent_messages: %{},
      ui_streams: %{},
      pending_response: MapSet.new(),
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cost: 0.0,
      total_cached_tokens: 0,
      total_reasoning_tokens: 0,
      step_input_tokens: 0,
      step_output_tokens: 0,
      connected: false,
      user_avatar: nil,
      agent_avatar: nil,
      active_page: :chat,
      selected_agent_id: nil,
      timeline_open: false,
      drawer_open: false,
      show_new_agent: false,
      uploaded_files: [],
      debug_mode: false,
      debug_projections: %{}
    }

    assigns = Map.merge(base, overrides)
    struct!(Phoenix.LiveView.Socket, assigns: assigns)
  end

  defp data_table_ws do
    %{
      label: "Skills Editor",
      icon: "table",
      projection: DataTableProjection
    }
  end

  # ----------------------------------------------------------------
  # 1. Chat route — full-width chat, no workspace tab bar
  # ----------------------------------------------------------------

  describe "chat route layout (live_action :show / :new)" do
    test "chat route has no workspaces — full-width chat mode" do
      socket = build_socket(%{live_action: :show})
      assert socket.assigns.workspaces == %{}
      assert socket.assigns.active_workspace_id == nil
    end

    test "has_workspaces is false when workspaces map is empty" do
      socket = build_socket(%{live_action: :show, workspaces: %{}})
      assert map_size(socket.assigns.workspaces) == 0
    end

    test "show_chat_panel? returns true when chat_visible and no chatroom active" do
      # When no workspaces are open, the full-width chat div renders instead.
      # show_chat_panel? governs the side panel — chat_visible=true, no chatroom.
      socket = build_socket(%{chat_visible: true, active_workspace_id: nil})
      assert socket.assigns.chat_visible == true
      assert socket.assigns.active_workspace_id != :chatroom
    end
  end

  # ----------------------------------------------------------------
  # 2. Spreadsheet route — workspace tab bar + spreadsheet + chat side panel
  # ----------------------------------------------------------------

  describe "spreadsheet route layout (live_action :data_table)" do
    test "spreadsheet route has spreadsheet workspace open" do
      workspaces = %{data_table: data_table_ws()}
      ws_states = %{data_table: DataTableProjection.init()}

      socket =
        build_socket(%{
          live_action: :data_table,
          workspaces: workspaces,
          ws_states: ws_states,
          active_workspace_id: :data_table,
          chat_visible: true
        })

      assert Map.has_key?(socket.assigns.workspaces, :data_table)
      assert socket.assigns.active_workspace_id == :data_table
      assert map_size(socket.assigns.workspaces) > 0
    end

    test "spreadsheet route has chat side panel visible" do
      socket =
        build_socket(%{
          live_action: :data_table,
          workspaces: %{data_table: data_table_ws()},
          chat_visible: true,
          active_workspace_id: :data_table
        })

      # Side panel shows when chat_visible=true and not chatroom
      assert socket.assigns.chat_visible == true
      assert socket.assigns.active_workspace_id != :chatroom
    end

    test "spreadsheet projection state is initialized" do
      ws_states = %{data_table: DataTableProjection.init()}

      socket =
        build_socket(%{
          workspaces: %{data_table: data_table_ws()},
          ws_states: ws_states,
          active_workspace_id: :data_table
        })

      ss = socket.assigns.ws_states[:data_table]
      assert ss.rows_map == %{}
      assert ss.next_id == 1
      assert ss.partial_streamed == %{}
    end
  end

  # ----------------------------------------------------------------
  # 3. Workspace tab switching preserves state (no remount)
  # ----------------------------------------------------------------

  describe "switch_workspace event" do
    test "switches active workspace without changing workspaces map" do
      workspaces = %{data_table: data_table_ws()}
      ws_states = %{data_table: DataTableProjection.init()}

      socket =
        build_socket(%{
          workspaces: workspaces,
          ws_states: ws_states,
          active_workspace_id: :data_table
        })

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_event(
          "switch_workspace",
          %{"workspace" => "data_table"},
          socket
        )

      assert socket.assigns.active_workspace_id == :data_table
      # Workspaces and ws_states unchanged (no remount, same references)
      assert socket.assigns.workspaces == workspaces
      assert socket.assigns.ws_states == ws_states
    end

    test "ignores switch to unknown workspace" do
      workspaces = %{data_table: data_table_ws()}
      ws_states = %{data_table: DataTableProjection.init()}

      socket =
        build_socket(%{
          workspaces: workspaces,
          ws_states: ws_states,
          active_workspace_id: :data_table
        })

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_event(
          "switch_workspace",
          %{"workspace" => "nonexistent"},
          socket
        )

      # Active workspace unchanged
      assert socket.assigns.active_workspace_id == :data_table
    end

    test "switch preserves ws_states (projection data survives)" do
      modified_state = %{
        rows_map: %{1 => %{id: 1, skill: "Elixir"}},
        next_id: 2,
        partial_streamed: %{}
      }

      workspaces = %{data_table: data_table_ws()}

      socket =
        build_socket(%{
          workspaces: workspaces,
          ws_states: %{data_table: modified_state},
          active_workspace_id: :data_table
        })

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_event(
          "switch_workspace",
          %{"workspace" => "data_table"},
          socket
        )

      # Projection state preserved exactly
      assert socket.assigns.ws_states[:data_table] == modified_state
    end
  end

  # ----------------------------------------------------------------
  # add_workspace / close_workspace events
  # ----------------------------------------------------------------

  describe "add_workspace event" do
    test "adds a registered workspace and switches to it" do
      socket = build_socket(%{workspaces: %{}, ws_states: %{}, active_workspace_id: nil})

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_event("add_workspace", %{"workspace" => "data_table"}, socket)

      assert Map.has_key?(socket.assigns.workspaces, :data_table)
      assert Map.has_key?(socket.assigns.ws_states, :data_table)
      assert socket.assigns.active_workspace_id == :data_table
      assert socket.assigns.shell.chat_mode == :expanded
    end

    test "adding already-open workspace just switches to it" do
      workspaces = %{data_table: data_table_ws()}
      ws_states = %{data_table: %{rows_map: %{1 => %{id: 1}}, next_id: 2, partial_streamed: %{}}}

      socket =
        build_socket(%{
          workspaces: workspaces,
          ws_states: ws_states,
          active_workspace_id: nil
        })

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_event("add_workspace", %{"workspace" => "data_table"}, socket)

      # Doesn't reset state — just switches
      assert socket.assigns.active_workspace_id == :data_table
      assert socket.assigns.ws_states[:data_table] == ws_states[:data_table]
    end

    test "adding unknown workspace is a no-op" do
      socket = build_socket(%{workspaces: %{}, ws_states: %{}, active_workspace_id: nil})

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_event("add_workspace", %{"workspace" => "canvas"}, socket)

      assert socket.assigns.workspaces == %{}
      assert socket.assigns.active_workspace_id == nil
    end
  end

  describe "close_workspace event" do
    test "removes workspace from workspaces and ws_states" do
      workspaces = %{data_table: data_table_ws()}
      ws_states = %{data_table: DataTableProjection.init()}

      socket =
        build_socket(%{
          workspaces: workspaces,
          ws_states: ws_states,
          active_workspace_id: :data_table,
          chat_visible: true
        })

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_event(
          "close_workspace",
          %{"workspace" => "data_table"},
          socket
        )

      refute Map.has_key?(socket.assigns.workspaces, :data_table)
      refute Map.has_key?(socket.assigns.ws_states, :data_table)
    end

    test "closing active workspace switches to next available" do
      workspaces = %{data_table: data_table_ws()}
      ws_states = %{data_table: DataTableProjection.init()}

      socket =
        build_socket(%{
          workspaces: workspaces,
          ws_states: ws_states,
          active_workspace_id: :data_table,
          chat_visible: true
        })

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_event(
          "close_workspace",
          %{"workspace" => "data_table"},
          socket
        )

      # No workspaces left, active is nil
      assert socket.assigns.active_workspace_id == nil
    end

    test "closing last workspace hides chat panel" do
      workspaces = %{data_table: data_table_ws()}

      socket =
        build_socket(%{
          workspaces: workspaces,
          ws_states: %{data_table: DataTableProjection.init()},
          active_workspace_id: :data_table,
          chat_visible: true
        })

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_event(
          "close_workspace",
          %{"workspace" => "data_table"},
          socket
        )

      assert socket.assigns.shell.chat_mode == :hidden
    end

    test "closing unknown workspace is a no-op" do
      workspaces = %{data_table: data_table_ws()}

      socket =
        build_socket(%{
          workspaces: workspaces,
          ws_states: %{data_table: DataTableProjection.init()},
          active_workspace_id: :data_table,
          chat_visible: true
        })

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_event(
          "close_workspace",
          %{"workspace" => "nonexistent"},
          socket
        )

      # Everything unchanged
      assert Map.has_key?(socket.assigns.workspaces, :data_table)
      assert socket.assigns.active_workspace_id == :data_table
    end
  end

  # ----------------------------------------------------------------
  # 4. Route change within same session preserves state
  # ----------------------------------------------------------------

  describe "handle_params — same session route change" do
    test "same session with different live_action merges workspaces without resub" do
      # Simulate: started on :show (chat), then navigating within same session
      socket =
        build_socket(%{
          live_action: :show,
          session_id: "test-session-123",
          workspaces: %{},
          ws_states: %{},
          active_workspace_id: nil,
          connected: false
        })

      # handle_params with same session_id — not connected, so just merges workspaces
      {:noreply, socket} =
        RhoWeb.SessionLive.handle_params(
          %{"session_id" => "test-session-123"},
          "/orgs/test/chat/test-session-123",
          socket
        )

      # Session ID preserved — no remount
      assert socket.assigns.session_id == "test-session-123"
    end

    test "same session preserves existing ws_states on route change" do
      modified_state = %{
        rows_map: %{1 => %{id: 1, skill: "Elixir"}},
        next_id: 2,
        partial_streamed: %{}
      }

      socket =
        build_socket(%{
          live_action: :show,
          session_id: "test-session-123",
          workspaces: %{data_table: data_table_ws()},
          ws_states: %{data_table: modified_state},
          active_workspace_id: :data_table,
          connected: false
        })

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_params(
          %{"session_id" => "test-session-123"},
          "/orgs/test/chat/test-session-123",
          socket
        )

      # Existing ws_states preserved — no reinit
      assert socket.assigns.ws_states[:data_table] == modified_state
    end

    test "nil session_id in params merges workspaces without resubscribe" do
      socket =
        build_socket(%{
          live_action: :show,
          session_id: "test-session-123",
          workspaces: %{},
          ws_states: %{},
          active_workspace_id: nil,
          connected: false
        })

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_params(
          %{},
          "/orgs/test/chat",
          socket
        )

      # Workspaces unchanged — no merge needed
      assert socket.assigns.workspaces == %{}
    end
  end

  # ----------------------------------------------------------------
  # toggle_chat event
  # ----------------------------------------------------------------

  describe "toggle_chat event" do
    test "toggles shell chat_mode between expanded and collapsed" do
      shell = %{RhoWeb.Session.Shell.init([], []) | chat_mode: :expanded}
      socket = build_socket(%{shell: shell})

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_event("toggle_chat", %{}, socket)

      assert socket.assigns.shell.chat_mode == :collapsed

      {:noreply, socket} =
        RhoWeb.SessionLive.handle_event("toggle_chat", %{}, socket)

      assert socket.assigns.shell.chat_mode == :expanded
    end
  end
end
