defmodule RhoWeb.Projections.DataTableProjectionTest do
  use ExUnit.Case, async: true

  alias RhoWeb.Projections.DataTableProjection

  defp signal(suffix, data) do
    %{type: "rho.session.test.#{suffix}", data: data}
  end

  describe "handles?/1" do
    test "matches spreadsheet signal suffixes" do
      assert DataTableProjection.handles?("rho.session.abc.data_table_rows_delta")
      assert DataTableProjection.handles?("rho.session.abc.data_table_replace_all")
      assert DataTableProjection.handles?("rho.session.abc.data_table_update_cells")
      assert DataTableProjection.handles?("rho.session.abc.data_table_delete_rows")
      assert DataTableProjection.handles?("rho.session.abc.structured_partial")
    end

    test "rejects non-spreadsheet signals" do
      refute DataTableProjection.handles?("rho.session.abc.text_delta")
      refute DataTableProjection.handles?("rho.session.abc.turn_finished")
      refute DataTableProjection.handles?("rho.session.abc.tool_start")
    end
  end

  describe "init/0" do
    test "returns empty initial state" do
      state = DataTableProjection.init()
      assert state.rows_map == %{}
      assert state.next_id == 1
      assert state.partial_streamed == %{}
      assert state.pending_ops == MapSet.new()
      assert state.cell_timestamps == %{}
    end
  end

  describe "reduce - rows_delta" do
    test "appends rows with auto-incrementing IDs" do
      state = DataTableProjection.init()

      rows = [
        %{"skill_name" => "Elixir", "level" => 1},
        %{"skill_name" => "Phoenix", "level" => 2}
      ]

      state = DataTableProjection.reduce(state, signal("data_table_rows_delta", %{rows: rows}))

      assert map_size(state.rows_map) == 2
      assert state.next_id == 3
      assert state.rows_map[1].skill_name == "Elixir"
      assert state.rows_map[2].skill_name == "Phoenix"
    end

    test "successive deltas accumulate rows" do
      state = DataTableProjection.init()

      state =
        DataTableProjection.reduce(
          state,
          signal("data_table_rows_delta", %{rows: [%{"skill_name" => "A"}]})
        )

      state =
        DataTableProjection.reduce(
          state,
          signal("data_table_rows_delta", %{rows: [%{"skill_name" => "B"}]})
        )

      assert map_size(state.rows_map) == 2
      assert state.next_id == 3
      assert state.rows_map[1].skill_name == "A"
      assert state.rows_map[2].skill_name == "B"
    end

    test "skips rows already streamed via partial" do
      state = %{DataTableProjection.init() | partial_streamed: %{"agent1" => 2}}

      rows = [
        %{"skill_name" => "A"},
        %{"skill_name" => "B"}
      ]

      state =
        DataTableProjection.reduce(
          state,
          signal("data_table_rows_delta", %{rows: rows, agent_id: "agent1"})
        )

      # Both rows skipped (already == count), partial decremented
      assert map_size(state.rows_map) == 0
      assert state.partial_streamed["agent1"] == 0
    end
  end

  describe "reduce - replace_all" do
    test "resets state to init" do
      state = %{
        rows_map: %{1 => %{id: 1, skill_name: "X"}},
        next_id: 5,
        partial_streamed: %{"a" => 3},
        pending_ops: MapSet.new(["op1"]),
        cell_timestamps: %{{1, :skill_name} => 100}
      }

      state = DataTableProjection.reduce(state, signal("data_table_replace_all", %{}))

      assert state.rows_map == %{}
      assert state.next_id == 1
      assert state.partial_streamed == %{}
      assert state.pending_ops == MapSet.new()
      assert state.cell_timestamps == %{}
    end
  end

  describe "reduce - update_cells" do
    test "updates specific cell values" do
      state = %{
        rows_map: %{1 => %{id: 1, skill_name: "Old", level: 1}},
        next_id: 2,
        partial_streamed: %{}
      }

      changes = [%{"id" => 1, "field" => "skill_name", "value" => "New"}]

      state =
        DataTableProjection.reduce(
          state,
          signal("data_table_update_cells", %{changes: changes})
        )

      assert state.rows_map[1].skill_name == "New"
      assert state.rows_map[1].level == 1
    end

    test "ignores changes for non-existent rows" do
      state = %{rows_map: %{}, next_id: 1, partial_streamed: %{}}
      changes = [%{"id" => 99, "field" => "skill_name", "value" => "Ghost"}]

      state =
        DataTableProjection.reduce(
          state,
          signal("data_table_update_cells", %{changes: changes})
        )

      assert state.rows_map == %{}
    end
  end

  describe "reduce - delete_rows" do
    test "removes rows by ID" do
      state = %{
        rows_map: %{
          1 => %{id: 1, skill_name: "A"},
          2 => %{id: 2, skill_name: "B"},
          3 => %{id: 3, skill_name: "C"}
        },
        next_id: 4,
        partial_streamed: %{}
      }

      state =
        DataTableProjection.reduce(
          state,
          signal("data_table_delete_rows", %{ids: [1, 3]})
        )

      assert map_size(state.rows_map) == 1
      assert state.rows_map[2].skill_name == "B"
    end
  end

  describe "reduce - structured_partial" do
    test "streams rows from partial JSON" do
      state = DataTableProjection.init()

      data = %{
        agent_id: "agent1",
        parsed: %{
          "action" => "add_rows",
          "action_input" => %{
            "rows_json" => ~s([{"skill_name": "Elixir"}, {"skill_name": "Phoenix"}])
          }
        }
      }

      state = DataTableProjection.reduce(state, signal("structured_partial", data))

      assert map_size(state.rows_map) == 2
      assert state.partial_streamed["agent1"] == 2
    end

    test "incrementally adds new rows from growing partial JSON" do
      state = DataTableProjection.init()

      # First partial with 1 row
      data1 = %{
        agent_id: "agent1",
        parsed: %{
          "action" => "add_rows",
          "action_input" => %{
            "rows_json" => ~s([{"skill_name": "A"}])
          }
        }
      }

      state = DataTableProjection.reduce(state, signal("structured_partial", data1))
      assert map_size(state.rows_map) == 1

      # Second partial with 2 rows (1 already seen)
      data2 = %{
        agent_id: "agent1",
        parsed: %{
          "action" => "add_rows",
          "action_input" => %{
            "rows_json" => ~s([{"skill_name": "A"}, {"skill_name": "B"}])
          }
        }
      }

      state = DataTableProjection.reduce(state, signal("structured_partial", data2))
      assert map_size(state.rows_map) == 2
      assert state.partial_streamed["agent1"] == 2
    end
  end

  describe "replay produces identical state" do
    test "replaying a sequence of signals produces the same final state" do
      signals = [
        signal("data_table_rows_delta", %{rows: [%{"skill_name" => "A", "level" => 1}]}),
        signal("data_table_rows_delta", %{rows: [%{"skill_name" => "B", "level" => 2}]}),
        signal("data_table_update_cells", %{
          changes: [%{"id" => 1, "field" => "skill_name", "value" => "A+"}]
        }),
        signal("data_table_delete_rows", %{ids: [2]}),
        signal("data_table_rows_delta", %{rows: [%{"skill_name" => "C", "level" => 3}]})
      ]

      run = fn ->
        Enum.reduce(signals, DataTableProjection.init(), &DataTableProjection.reduce(&2, &1))
      end

      assert run.() == run.()
    end
  end

  describe "handles?/1 - user_edit" do
    test "matches data_table_user_edit suffix" do
      assert DataTableProjection.handles?("rho.session.abc.data_table_user_edit")
    end
  end

  describe "rows_delta with stable row_id" do
    test "uses row_id from payload when present" do
      state = DataTableProjection.init()

      rows = [
        %{"skill_name" => "Elixir", "row_id" => "abc123"},
        %{"skill_name" => "Phoenix", "row_id" => "def456"}
      ]

      state = DataTableProjection.reduce(state, signal("data_table_rows_delta", %{rows: rows}))

      assert Map.has_key?(state.rows_map, "abc123")
      assert Map.has_key?(state.rows_map, "def456")
      assert state.rows_map["abc123"].skill_name == "Elixir"
      assert state.rows_map["def456"].skill_name == "Phoenix"
      # next_id incremented even for stable IDs (used for sort_order)
      assert state.next_id == 3
    end

    test "falls back to auto-increment when row_id absent" do
      state = DataTableProjection.init()
      rows = [%{"skill_name" => "A"}]
      state = DataTableProjection.reduce(state, signal("data_table_rows_delta", %{rows: rows}))
      assert Map.has_key?(state.rows_map, 1)
      assert state.next_id == 2
    end
  end

  describe "apply_optimistic_edit/5" do
    test "applies edit and records pending op" do
      state = %{
        DataTableProjection.init()
        | rows_map: %{"r1" => %{id: "r1", skill_name: "Old", level: 1}},
          next_id: 2
      }

      state = DataTableProjection.apply_optimistic_edit(state, "r1", :skill_name, "New", "op1")

      assert state.rows_map["r1"].skill_name == "New"
      assert MapSet.member?(state.pending_ops, "op1")
    end

    test "no-op for missing row" do
      state = DataTableProjection.init()
      state = DataTableProjection.apply_optimistic_edit(state, "missing", :skill_name, "X", "op1")
      assert state.rows_map == %{}
      assert state.pending_ops == MapSet.new()
    end
  end

  describe "reduce - user_edit" do
    defp user_edit_signal(data, emitted_at \\ 100) do
      %{
        type: "rho.session.test.data_table_user_edit",
        data: data,
        meta: %{emitted_at: emitted_at}
      }
    end

    test "remote edit is applied" do
      state = %{
        DataTableProjection.init()
        | rows_map: %{"r1" => %{id: "r1", skill_name: "Old", level: 1}},
          next_id: 2
      }

      state =
        DataTableProjection.reduce(
          state,
          user_edit_signal(%{
            row_id: "r1",
            field: "skill_name",
            value: "New",
            client_op_id: "op1"
          })
        )

      assert state.rows_map["r1"].skill_name == "New"
    end

    test "deduplicates own optimistic op" do
      state = %{
        DataTableProjection.init()
        | rows_map: %{"r1" => %{id: "r1", skill_name: "Optimistic"}},
          pending_ops: MapSet.new(["op1"])
      }

      state =
        DataTableProjection.reduce(
          state,
          user_edit_signal(%{
            row_id: "r1",
            field: "skill_name",
            value: "Confirmed",
            client_op_id: "op1"
          })
        )

      # Should NOT overwrite — just clear the pending op
      assert state.rows_map["r1"].skill_name == "Optimistic"
      refute MapSet.member?(state.pending_ops, "op1")
    end

    test "last-write-wins by emitted_at" do
      state = %{
        DataTableProjection.init()
        | rows_map: %{"r1" => %{id: "r1", skill_name: "First"}},
          cell_timestamps: %{{"r1", :skill_name} => 200}
      }

      # Older edit should be rejected
      state =
        DataTableProjection.reduce(
          state,
          user_edit_signal(
            %{row_id: "r1", field: "skill_name", value: "Stale", client_op_id: "op_old"},
            100
          )
        )

      assert state.rows_map["r1"].skill_name == "First"

      # Newer edit should be accepted
      state =
        DataTableProjection.reduce(
          state,
          user_edit_signal(
            %{row_id: "r1", field: "skill_name", value: "Latest", client_op_id: "op_new"},
            300
          )
        )

      assert state.rows_map["r1"].skill_name == "Latest"
    end

    test "ignores edit for non-existent row" do
      state = DataTableProjection.init()

      state =
        DataTableProjection.reduce(
          state,
          user_edit_signal(%{
            row_id: "missing",
            field: "skill_name",
            value: "Ghost",
            client_op_id: "op1"
          })
        )

      assert state.rows_map == %{}
    end
  end

  describe "handles?/1 - schema_change" do
    test "matches data_table_schema_change suffix" do
      assert DataTableProjection.handles?("rho.session.abc.data_table_schema_change")
    end
  end

  describe "init/1 with schema" do
    test "stores schema and known fields from schema" do
      schema = RhoWeb.DataTable.Schemas.role_profile()
      state = DataTableProjection.init(schema)

      assert state.schema == schema
      assert state.mode_label == nil
      assert "required_level" in state.known_fields
      refute "level_description" in state.known_fields
    end
  end

  describe "reduce - schema_change" do
    test "updates schema and known fields" do
      state = DataTableProjection.init()
      assert state.schema == nil

      role_schema = RhoWeb.DataTable.Schemas.role_profile()

      state =
        DataTableProjection.reduce(
          state,
          signal("data_table_schema_change", %{
            schema: role_schema,
            mode_label: "Role Profile — Senior Data Engineer"
          })
        )

      assert state.schema == role_schema
      assert state.mode_label == "Role Profile — Senior Data Engineer"
      assert "required_level" in state.known_fields
    end

    test "updates only mode_label when schema is nil" do
      lib_schema = RhoWeb.DataTable.Schemas.skill_library()
      state = DataTableProjection.init(lib_schema)

      state =
        DataTableProjection.reduce(
          state,
          signal("data_table_schema_change", %{schema: nil, mode_label: "Editing: Skill Library"})
        )

      assert state.schema == lib_schema
      assert state.mode_label == "Editing: Skill Library"
    end

    test "no-op when both schema and mode_label are nil" do
      state = DataTableProjection.init()
      original = state

      state =
        DataTableProjection.reduce(
          state,
          signal("data_table_schema_change", %{})
        )

      assert state == original
    end
  end

  describe "extract_complete_rows/1" do
    test "parses valid JSON array" do
      assert DataTableProjection.extract_complete_rows(~s([{"a": 1}, {"b": 2}])) ==
               [%{"a" => 1}, %{"b" => 2}]
    end

    test "extracts complete objects from incomplete JSON" do
      assert DataTableProjection.extract_complete_rows(~s([{"a": 1}, {"b": 2)) ==
               [%{"a" => 1}]
    end
  end

  describe "filter_rows/2" do
    test "returns all rows for nil filter" do
      rows = [%{skill_name: "A"}, %{skill_name: "B"}]
      assert DataTableProjection.filter_rows(rows, nil) == rows
    end

    test "returns all rows for empty filter" do
      rows = [%{skill_name: "A"}, %{skill_name: "B"}]
      assert DataTableProjection.filter_rows(rows, %{}) == rows
    end

    test "filters by string key field value" do
      rows = [%{skill_name: "A", level: 1}, %{skill_name: "B", level: 2}]

      assert DataTableProjection.filter_rows(rows, %{"level" => 2}) == [
               %{skill_name: "B", level: 2}
             ]
    end
  end
end
