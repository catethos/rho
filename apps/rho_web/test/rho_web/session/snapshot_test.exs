defmodule RhoWeb.Session.SnapshotTest do
  use ExUnit.Case, async: true

  alias RhoWeb.Session.Snapshot

  @session_id "test_session_#{:erlang.unique_integer([:positive])}"

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "rho_snapshot_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    %{workspace: workspace}
  end

  describe "save/3 and load/2" do
    test "round-trip produces identical state", %{workspace: workspace} do
      state = sample_state()

      assert :ok = Snapshot.save(@session_id, workspace, state)
      assert {:ok, loaded} = Snapshot.load(@session_id, workspace)

      # snapshot_at is added by save, so check the original fields
      assert loaded.agents == state.agents
      assert loaded.agent_messages == state.agent_messages
      assert loaded.active_agent_id == state.active_agent_id
      assert loaded.agent_tab_order == state.agent_tab_order
      assert loaded.total_input_tokens == state.total_input_tokens
      assert loaded.total_output_tokens == state.total_output_tokens
      assert loaded.total_cost == state.total_cost
      # ws_states round-trips — integer map keys become strings in JSON
      assert loaded.ws_states.spreadsheet.rows_map["1"].skill_name == "Testing"
      assert loaded.ws_states.spreadsheet.next_id == state.ws_states.spreadsheet.next_id
      assert loaded.debug_mode == state.debug_mode
      assert is_integer(loaded.snapshot_at)
    end

    test "load returns :none when no snapshot exists", %{workspace: workspace} do
      assert :none = Snapshot.load("nonexistent", workspace)
    end

    test "delete removes the snapshot file", %{workspace: workspace} do
      assert :ok = Snapshot.save(@session_id, workspace, %{})
      assert {:ok, _} = Snapshot.load(@session_id, workspace)

      assert :ok = Snapshot.delete(@session_id, workspace)
      assert :none = Snapshot.load(@session_id, workspace)
    end

    test "delete is idempotent when file doesn't exist", %{workspace: workspace} do
      assert :ok = Snapshot.delete("nonexistent", workspace)
    end
  end

  describe "serialization" do
    test "MapSet round-trips correctly", %{workspace: workspace} do
      state = %{ws_states: %{spreadsheet: %{collapsed: MapSet.new(["cat-a", "cat-b"])}}}

      assert :ok = Snapshot.save(@session_id, workspace, state)
      assert {:ok, loaded} = Snapshot.load(@session_id, workspace)

      assert loaded.ws_states.spreadsheet.collapsed == MapSet.new(["cat-a", "cat-b"])
    end

    test "atom values round-trip when atoms already exist", %{workspace: workspace} do
      # These atoms already exist because they're used in the codebase
      state = %{
        active_page: :chat,
        agents: %{
          "agent_1" => %{
            role: :worker,
            status: :busy
          }
        }
      }

      assert :ok = Snapshot.save(@session_id, workspace, state)
      assert {:ok, loaded} = Snapshot.load(@session_id, workspace)

      assert loaded.active_page == :chat
      assert loaded.agents["agent_1"].role == :worker
      assert loaded.agents["agent_1"].status == :busy
    end

    test "unknown atom strings stay as strings" do
      raw = %{
        "__type__" => "atom",
        "value" => "zzzz_no_such_atom_exists_#{:erlang.unique_integer([:positive])}"
      }

      result = Snapshot.deserialize(raw)
      assert is_binary(result)
    end

    test "PIDs are dropped (serialized as nil)", %{workspace: workspace} do
      state = %{some_pid: self()}

      assert :ok = Snapshot.save(@session_id, workspace, state)
      assert {:ok, loaded} = Snapshot.load(@session_id, workspace)

      assert loaded.some_pid == nil
    end

    test "nested maps with integer keys round-trip as string keys", %{workspace: workspace} do
      state = %{
        ws_states: %{
          spreadsheet: %{
            rows_map: %{
              1 => %{id: 1, skill_name: "Elixir"},
              2 => %{id: 2, skill_name: "Phoenix"}
            }
          }
        }
      }

      assert :ok = Snapshot.save(@session_id, workspace, state)
      assert {:ok, loaded} = Snapshot.load(@session_id, workspace)

      assert loaded.ws_states.spreadsheet.rows_map["1"].skill_name == "Elixir"
      assert loaded.ws_states.spreadsheet.rows_map["2"].skill_name == "Phoenix"
    end

    test "boolean and nil values are preserved", %{workspace: workspace} do
      state = %{debug_mode: true, active_agent_id: nil}

      assert :ok = Snapshot.save(@session_id, workspace, state)
      assert {:ok, loaded} = Snapshot.load(@session_id, workspace)

      assert loaded.debug_mode == true
      assert loaded.active_agent_id == nil
    end

    test "pending_ops MapSet round-trips correctly", %{workspace: workspace} do
      state = %{
        ws_states: %{
          spreadsheet: %{
            rows_map: %{},
            next_id: 1,
            partial_streamed: %{},
            pending_ops: MapSet.new(["op_abc", "op_def"]),
            cell_timestamps: %{}
          }
        }
      }

      assert :ok = Snapshot.save(@session_id, workspace, state)
      assert {:ok, loaded} = Snapshot.load(@session_id, workspace)

      assert loaded.ws_states.spreadsheet.pending_ops == MapSet.new(["op_abc", "op_def"])
    end

    test "cell_timestamps with tuple keys round-trip correctly", %{workspace: workspace} do
      state = %{
        ws_states: %{
          spreadsheet: %{
            rows_map: %{},
            next_id: 1,
            partial_streamed: %{},
            pending_ops: MapSet.new(),
            cell_timestamps: %{
              {"row_abc", :skill_name} => 1000,
              {"row_def", :level} => 2000,
              {1, :skill_name} => 3000
            }
          }
        }
      }

      assert :ok = Snapshot.save(@session_id, workspace, state)
      assert {:ok, loaded} = Snapshot.load(@session_id, workspace)

      ts = loaded.ws_states.spreadsheet.cell_timestamps
      assert ts[{"row_abc", :skill_name}] == 1000
      assert ts[{"row_def", :level}] == 2000
      assert ts[{1, :skill_name}] == 3000
    end

    test "tuple values round-trip correctly" do
      serialized = Snapshot.serialize(%{pair: {:hello, :world}})
      deserialized = Snapshot.deserialize(serialized)

      assert deserialized.pair == {:hello, :world}
    end

    test "list values round-trip correctly", %{workspace: workspace} do
      state = %{agent_tab_order: ["agent_1", "agent_2", "agent_3"]}

      assert :ok = Snapshot.save(@session_id, workspace, state)
      assert {:ok, loaded} = Snapshot.load(@session_id, workspace)

      assert loaded.agent_tab_order == ["agent_1", "agent_2", "agent_3"]
    end
  end

  describe "build_snapshot/1" do
    test "extracts only snapshotable fields" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          # Included fields
          agents: %{"a1" => %{role: :worker}},
          agent_messages: %{"a1" => [%{id: "m1", content: "hello"}]},
          active_agent_id: "a1",
          agent_tab_order: ["a1"],
          active_page: :chat,
          total_input_tokens: 100,
          total_output_tokens: 50,
          total_cost: 0.01,
          total_cached_tokens: 10,
          total_reasoning_tokens: 5,
          step_input_tokens: 20,
          step_output_tokens: 10,
          debug_mode: false,
          debug_projections: %{},
          ws_states: %{spreadsheet: %{rows_map: %{}, next_id: 1, partial_streamed: %{}}},
          # Excluded fields (process-specific)
          inflight: %{"a1" => "streaming..."},
          bus_subs: [:some_ref],
          connected: true,
          uploads: %{},
          ui_streams: %{},
          user_avatar: "data:image/png;base64,..."
        }
      }

      snapshot = Snapshot.build_snapshot(socket)

      # Included
      assert snapshot.agents == %{"a1" => %{role: :worker}}
      assert snapshot.active_agent_id == "a1"
      assert snapshot.active_page == :chat
      assert snapshot.total_input_tokens == 100
      assert snapshot.ws_states.spreadsheet.rows_map == %{}

      # Excluded
      refute Map.has_key?(snapshot, :inflight)
      refute Map.has_key?(snapshot, :bus_subs)
      refute Map.has_key?(snapshot, :connected)
      refute Map.has_key?(snapshot, :uploads)
      refute Map.has_key?(snapshot, :ui_streams)
      refute Map.has_key?(snapshot, :user_avatar)
    end
  end

  describe "apply_snapshot/2" do
    test "restores snapshot fields into socket assigns" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          agents: %{},
          active_agent_id: nil,
          total_input_tokens: 0
        }
      }

      snapshot = %{
        agents: %{"a1" => %{role: :worker}},
        active_agent_id: "a1",
        total_input_tokens: 500,
        snapshot_at: 1_700_000_000_000
      }

      updated = Snapshot.apply_snapshot(socket, snapshot)

      assert updated.assigns.agents == %{"a1" => %{role: :worker}}
      assert updated.assigns.active_agent_id == "a1"
      assert updated.assigns.total_input_tokens == 500
      # snapshot_at is not applied to assigns
      refute Map.has_key?(updated.assigns, :snapshot_at)
    end
  end

  describe "full round-trip: build -> save -> load -> apply" do
    test "complete lifecycle preserves state", %{workspace: workspace} do
      original_assigns = %{
        __changed__: %{},
        agents: %{
          "primary_agent" => %{
            agent_id: "primary_agent",
            role: :primary,
            status: :idle,
            step: 3,
            max_steps: 10,
            model: nil,
            depth: 0,
            capabilities: []
          }
        },
        agent_messages: %{
          "primary_agent" => [
            %{id: "user_1", role: :user, type: :text, content: "Hello"},
            %{id: "asst_1", role: :assistant, type: :text, content: "Hi there"}
          ]
        },
        active_agent_id: "primary_agent",
        agent_tab_order: ["primary_agent"],
        active_page: :chat,
        total_input_tokens: 1500,
        total_output_tokens: 800,
        total_cost: 0.05,
        total_cached_tokens: 200,
        total_reasoning_tokens: 100,
        step_input_tokens: 50,
        step_output_tokens: 25,
        debug_mode: false,
        debug_projections: %{},
        ws_states: %{
          spreadsheet: %{
            rows_map: %{
              1 => %{id: 1, category: "Engineering", cluster: "Backend", skill_name: "Elixir"},
              2 => %{id: 2, category: "Engineering", cluster: "Backend", skill_name: "Phoenix"}
            },
            next_id: 3,
            partial_streamed: %{}
          }
        },
        # These should be excluded
        inflight: %{"primary_agent" => %{text: "thinking..."}},
        bus_subs: [make_ref()],
        connected: true
      }

      source_socket = %Phoenix.LiveView.Socket{assigns: original_assigns}

      # Build snapshot (excludes process-specific state)
      snapshot = Snapshot.build_snapshot(source_socket)

      # Save to disk
      assert :ok = Snapshot.save(@session_id, workspace, snapshot)

      # Load from disk
      assert {:ok, loaded} = Snapshot.load(@session_id, workspace)

      # Apply to a fresh socket
      target_socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          agents: %{},
          active_agent_id: nil
        }
      }

      restored = Snapshot.apply_snapshot(target_socket, loaded)

      # Verify key fields survived the full cycle
      assert restored.assigns.active_agent_id == "primary_agent"
      assert restored.assigns.agent_tab_order == ["primary_agent"]
      assert restored.assigns.active_page == :chat
      assert restored.assigns.total_input_tokens == 1500
      assert restored.assigns.total_cost == 0.05
      assert restored.assigns.debug_mode == false

      # ws_states round-tripped
      ss = restored.assigns.ws_states.spreadsheet
      assert ss.next_id == 3
      assert ss.rows_map["1"].skill_name == "Elixir"

      # Messages survived
      msgs = restored.assigns.agent_messages["primary_agent"]
      assert length(msgs) == 2
      assert Enum.at(msgs, 0).content == "Hello"

      # Process-specific state was NOT restored
      refute Map.has_key?(restored.assigns, :inflight)
      refute Map.has_key?(restored.assigns, :bus_subs)
    end
  end

  describe "thread-aware save/load" do
    test "saves and loads with thread_id", %{workspace: workspace} do
      state = %{agents: %{"a1" => %{role: :worker}}, total_input_tokens: 42}

      assert :ok = Snapshot.save(@session_id, workspace, state, thread_id: "thread_abc")
      assert {:ok, loaded} = Snapshot.load(@session_id, workspace, thread_id: "thread_abc")

      assert loaded.agents["a1"].role == :worker
      assert loaded.total_input_tokens == 42
    end

    test "thread snapshots are isolated from each other", %{workspace: workspace} do
      state_a = %{total_input_tokens: 100}
      state_b = %{total_input_tokens: 200}

      :ok = Snapshot.save(@session_id, workspace, state_a, thread_id: "thread_a")
      :ok = Snapshot.save(@session_id, workspace, state_b, thread_id: "thread_b")

      {:ok, loaded_a} = Snapshot.load(@session_id, workspace, thread_id: "thread_a")
      {:ok, loaded_b} = Snapshot.load(@session_id, workspace, thread_id: "thread_b")

      assert loaded_a.total_input_tokens == 100
      assert loaded_b.total_input_tokens == 200
    end

    test "thread snapshot does not interfere with default snapshot", %{workspace: workspace} do
      default_state = %{total_input_tokens: 10}
      thread_state = %{total_input_tokens: 99}

      :ok = Snapshot.save(@session_id, workspace, default_state)
      :ok = Snapshot.save(@session_id, workspace, thread_state, thread_id: "thread_x")

      {:ok, loaded_default} = Snapshot.load(@session_id, workspace)
      {:ok, loaded_thread} = Snapshot.load(@session_id, workspace, thread_id: "thread_x")

      assert loaded_default.total_input_tokens == 10
      assert loaded_thread.total_input_tokens == 99
    end

    test "returns :none for nonexistent thread snapshot", %{workspace: workspace} do
      assert :none = Snapshot.load(@session_id, workspace, thread_id: "thread_nonexistent")
    end

    test "thread snapshots stored in snapshots/ subdirectory", %{workspace: workspace} do
      :ok = Snapshot.save(@session_id, workspace, %{x: 1}, thread_id: "thread_check")

      expected_path =
        Path.join([
          workspace,
          "_rho",
          "sessions",
          @session_id,
          "snapshots",
          "thread_check.json"
        ])

      assert File.exists?(expected_path)
    end
  end

  # --- Helpers ---

  defp sample_state do
    %{
      agents: %{
        "agent_1" => %{
          agent_id: "agent_1",
          role: :worker,
          status: :idle,
          model: nil,
          step: nil,
          max_steps: nil,
          depth: 0,
          capabilities: []
        }
      },
      agent_messages: %{
        "agent_1" => [
          %{id: "msg_1", role: :user, type: :text, content: "test message"}
        ]
      },
      active_agent_id: "agent_1",
      agent_tab_order: ["agent_1"],
      total_input_tokens: 100,
      total_output_tokens: 50,
      total_cost: 0.005,
      total_cached_tokens: 10,
      total_reasoning_tokens: 5,
      step_input_tokens: 20,
      step_output_tokens: 10,
      debug_mode: false,
      debug_projections: %{},
      ws_states: %{
        spreadsheet: %{
          rows_map: %{
            1 => %{id: 1, category: "Test", cluster: "Unit", skill_name: "Testing"}
          },
          next_id: 2,
          partial_streamed: %{}
        }
      }
    }
  end
end
