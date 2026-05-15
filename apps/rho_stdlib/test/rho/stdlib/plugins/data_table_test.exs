defmodule Rho.Stdlib.Plugins.DataTableTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias Rho.Stdlib.DataTable.Schema
  alias Rho.Stdlib.DataTable.Schema.Column
  alias Rho.Stdlib.Plugins.DataTable, as: Plugin

  setup do
    session_id = "plugin_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> DataTable.stop(session_id) end)
    {:ok, session_id: session_id}
  end

  defp library_schema do
    %Schema{
      name: "library",
      mode: :strict,
      columns: [
        %Column{name: :skill_name, type: :string, required?: true},
        %Column{name: :skill_description, type: :string}
      ],
      key_fields: [:skill_name]
    }
  end

  defp library_with_levels_schema do
    %Schema{
      name: "library",
      mode: :strict,
      columns: [
        %Column{name: :skill_name, type: :string, required?: true},
        %Column{name: :skill_description, type: :string}
      ],
      children_key: :proficiency_levels,
      child_columns: [
        %Column{name: :level, type: :integer, required?: true},
        %Column{name: :level_name, type: :string},
        %Column{name: :level_description, type: :string}
      ],
      child_key_fields: [:level],
      key_fields: [:skill_name]
    }
  end

  describe "prompt_sections/2" do
    test "returns [] without a session_id" do
      assert Plugin.prompt_sections([], %{}) == []
    end

    test "returns [] when DataTable.Server is not running", %{session_id: sid} do
      # Don't start the server.
      assert Plugin.prompt_sections([], %{session_id: sid}) == []
    end

    test "renders one section listing all tables", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())

      [section] = Plugin.prompt_sections([], %{session_id: sid})

      assert %Rho.PromptSection{
               key: :data_table_index,
               heading: "Workbench context",
               kind: :reference
             } = section

      assert section.body =~ "- main [generic_table]"
      assert section.body =~ "- library [skill_library]"
      # No table line carries the active marker.
      refute section.body =~ "[skill_library] currently open"
    end

    test "marks the active table when set", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())
      :ok = DataTable.set_active_table(sid, "library")

      [section] = Plugin.prompt_sections([], %{session_id: sid})
      lines = String.split(section.body, "\n")

      assert Enum.any?(lines, &(&1 == "- library [skill_library] currently open"))
      assert Enum.any?(lines, &(&1 == "- main [generic_table]"))
    end

    test "row_count reflects current rows", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())

      {:ok, _} =
        DataTable.add_rows(sid, [%{skill_name: "Python"}, %{skill_name: "Elixir"}],
          table: "library"
        )

      [section] = Plugin.prompt_sections([], %{session_id: sid})

      assert section.body =~ "summary: 2 skills"
    end

    test "shows the column names for the active table", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())
      :ok = DataTable.set_active_table(sid, "library")

      [section] = Plugin.prompt_sections([], %{session_id: sid})

      assert section.body =~ "columns: skill_name, skill_description"
    end

    test "does not list columns for non-active tables", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())
      :ok = DataTable.set_active_table(sid, "main")

      [section] = Plugin.prompt_sections([], %{session_id: sid})

      # The library table line should NOT carry a columns line.
      refute section.body =~ "columns: skill_name"
    end

    test "renders selection block under the active table", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())

      {:ok, [r1, r2]} =
        DataTable.add_rows(
          sid,
          [%{skill_name: "Python"}, %{skill_name: "Elixir"}],
          table: "library"
        )

      :ok = DataTable.set_active_table(sid, "library")
      :ok = DataTable.set_selection(sid, "library", [r1.id, r2.id])

      [section] = Plugin.prompt_sections([], %{session_id: sid})

      assert section.body =~ "selected: 2"
      assert section.body =~ "Selected rows in library:"
      assert section.body =~ "Python"
      assert section.body =~ "Elixir"
    end

    test "non-active table selections collapse to count only", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())

      {:ok, [r]} = DataTable.add_rows(sid, [%{skill_name: "Python"}], table: "library")

      :ok = DataTable.set_active_table(sid, "main")
      :ok = DataTable.set_selection(sid, "library", [r.id])

      [section] = Plugin.prompt_sections([], %{session_id: sid})

      assert section.body =~ "selected: 1"
      refute section.body =~ "Selected rows in library:"
      refute section.body =~ "Python"
    end

    test "truncates past the 10-row preview cap", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())

      rows = for i <- 1..12, do: %{skill_name: "Skill #{i}"}

      {:ok, inserted} = DataTable.add_rows(sid, rows, table: "library")
      :ok = DataTable.set_active_table(sid, "library")
      :ok = DataTable.set_selection(sid, "library", Enum.map(inserted, & &1.id))

      [section] = Plugin.prompt_sections([], %{session_id: sid})

      assert section.body =~ "selected: 12"
      assert section.body =~ "... + 2 more selected"
    end
  end

  describe "edit_row tool" do
    defp edit_row_execute(sid) do
      tools = Plugin.tools([], %{session_id: sid})
      [%{execute: execute}] = Enum.filter(tools, &(&1.tool.name == "edit_row"))
      execute
    end

    defp seed_library(sid) do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())

      {:ok, [py, el]} =
        DataTable.add_rows(
          sid,
          [
            %{skill_name: "Python", skill_description: "snake"},
            %{skill_name: "Elixir", skill_description: "lava"}
          ],
          table: "library"
        )

      %{python_id: py.id, elixir_id: el.id}
    end

    test "errors when no row matches", %{session_id: sid} do
      _ = seed_library(sid)
      execute = edit_row_execute(sid)

      assert {:error, msg} =
               execute.(
                 %{
                   table: "library",
                   match_json: ~s({"skill_name":"Rust"}),
                   set_json: ~s({"skill_description":"crab"})
                 },
                 %{}
               )

      assert msg =~ "no rows"
      assert msg =~ "library"
    end

    test "updates exactly one matching row", %{session_id: sid} do
      %{python_id: id} = seed_library(sid)
      execute = edit_row_execute(sid)

      assert {:ok, msg} =
               execute.(
                 %{
                   table: "library",
                   match_json: ~s({"skill_name":"Python"}),
                   set_json: ~s({"skill_description":"a snake"})
                 },
                 %{}
               )

      assert msg =~ "Updated row #{id}"

      {:ok, %{rows: [row]}} =
        DataTable.query_rows(sid, table: "library", filter: %{"skill_name" => "Python"})

      assert row[:skill_description] == "a snake"
    end

    test "errors on ambiguous locator (>1 rows match)", %{session_id: sid} do
      _ = seed_library(sid)

      # Add a duplicate description so two rows share that description.
      {:ok, _} =
        DataTable.add_rows(sid, [%{skill_name: "JavaScript", skill_description: "snake"}],
          table: "library"
        )

      execute = edit_row_execute(sid)

      assert {:error, msg} =
               execute.(
                 %{
                   table: "library",
                   match_json: ~s({"skill_description":"snake"}),
                   set_json: ~s({"skill_description":"reptile"})
                 },
                 %{}
               )

      assert msg =~ "ambiguous"
    end

    test "errors when neither flat params nor match_json provided", %{session_id: sid} do
      _ = seed_library(sid)
      execute = edit_row_execute(sid)

      assert {:error, msg} =
               execute.(%{table: "library", set_json: ~s({"x":1})}, %{})

      assert msg =~ "match_field+match_value"
    end

    test "errors on invalid JSON", %{session_id: sid} do
      _ = seed_library(sid)
      execute = edit_row_execute(sid)

      assert {:error, msg} =
               execute.(
                 %{table: "library", match_json: "not json", set_json: ~s({"x":1})},
                 %{}
               )

      assert msg =~ "match_json is not valid JSON"
    end

    test "errors on empty match_json object", %{session_id: sid} do
      _ = seed_library(sid)
      execute = edit_row_execute(sid)

      assert {:error, "match_json must be a non-empty object"} =
               execute.(
                 %{table: "library", match_json: "{}", set_json: ~s({"x":1})},
                 %{}
               )
    end

    test "flat-string params: match_field/match_value + set_field/set_value", %{
      session_id: sid
    } do
      %{python_id: id} = seed_library(sid)
      execute = edit_row_execute(sid)

      assert {:ok, msg} =
               execute.(
                 %{
                   table: "library",
                   match_field: "skill_name",
                   match_value: "Python",
                   set_field: "skill_description",
                   set_value: "a slithery friend"
                 },
                 %{}
               )

      assert msg =~ "Updated row #{id}"

      {:ok, %{rows: [row]}} =
        DataTable.query_rows(sid, table: "library", filter: %{"skill_name" => "Python"})

      assert row[:skill_description] == "a slithery friend"
    end

    test "flat-string match + JSON set composes", %{session_id: sid} do
      %{python_id: id} = seed_library(sid)
      execute = edit_row_execute(sid)

      assert {:ok, _msg} =
               execute.(
                 %{
                   table: "library",
                   match_field: "skill_name",
                   match_value: "Python",
                   set_json: ~s({"skill_description":"reptile"})
                 },
                 %{}
               )

      {:ok, %{rows: [row]}} =
        DataTable.query_rows(sid, table: "library", filter: %{"id" => id})

      assert row[:skill_description] == "reptile"
    end

    test "flat-string params win over conflicting JSON params", %{session_id: sid} do
      %{python_id: id} = seed_library(sid)
      execute = edit_row_execute(sid)

      # match_field/match_value selects Python; match_json (Elixir) is ignored.
      assert {:ok, msg} =
               execute.(
                 %{
                   table: "library",
                   match_field: "skill_name",
                   match_value: "Python",
                   match_json: ~s({"skill_name":"Elixir"}),
                   set_field: "skill_description",
                   set_value: "winner"
                 },
                 %{}
               )

      assert msg =~ "Updated row #{id}"
    end
  end

  describe "edit_row tool: nested child editing" do
    defp seed_python_with_levels(sid) do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_with_levels_schema())

      {:ok, [py]} =
        DataTable.add_rows(
          sid,
          [
            %{
              skill_name: "Python",
              skill_description: "snake",
              proficiency_levels: [
                %{level: 1, level_name: "Novice"},
                %{level: 3, level_name: "Practitioner"},
                %{level: 5, level_name: "Master"}
              ]
            }
          ],
          table: "library"
        )

      py
    end

    test "edits a single proficiency level via child_match_field/value", %{session_id: sid} do
      _ = seed_python_with_levels(sid)
      execute = edit_row_execute(sid)

      assert {:ok, msg} =
               execute.(
                 %{
                   table: "library",
                   match_field: "skill_name",
                   match_value: "Python",
                   child_match_field: "level",
                   child_match_value: "3",
                   set_field: "level_description",
                   set_value: "writes idiomatic code"
                 },
                 %{}
               )

      assert msg =~ "child"

      {:ok, %{rows: [row]}} =
        DataTable.query_rows(sid, table: "library", filter: %{"skill_name" => "Python"})

      level_3 = Enum.find(row[:proficiency_levels], &(&1[:level] == 3))
      assert level_3[:level_description] == "writes idiomatic code"

      level_1 = Enum.find(row[:proficiency_levels], &(&1[:level] == 1))
      refute Map.has_key?(level_1, :level_description)
    end

    test "errors when child_match_value matches no child", %{session_id: sid} do
      _ = seed_python_with_levels(sid)
      execute = edit_row_execute(sid)

      assert {:error, msg} =
               execute.(
                 %{
                   table: "library",
                   match_field: "skill_name",
                   match_value: "Python",
                   child_match_field: "level",
                   child_match_value: "99",
                   set_field: "level_description",
                   set_value: "..."
                 },
                 %{}
               )

      assert msg =~ "no_match"
    end

    test "errors with unknown_child_field on typo'd set_field", %{session_id: sid} do
      _ = seed_python_with_levels(sid)
      execute = edit_row_execute(sid)

      assert {:error, msg} =
               execute.(
                 %{
                   table: "library",
                   match_field: "skill_name",
                   match_value: "Python",
                   child_match_field: "level",
                   child_match_value: "3",
                   set_field: "level_descrption",
                   set_value: "..."
                 },
                 %{}
               )

      assert msg =~ "unknown_child_field"
    end
  end

  describe "query_table tool: child visibility" do
    defp query_table_execute(sid) do
      tools = Plugin.tools([], %{session_id: sid})
      [%{execute: execute}] = Enum.filter(tools, &(&1.tool.name == "query_table"))
      execute
    end

    test "does not elide the children_key column", %{session_id: sid} do
      _ = seed_python_with_levels(sid)
      execute = query_table_execute(sid)

      assert {:ok, json} =
               execute.(
                 %{table: "library", filter_field: "skill_name", filter_value: "Python"},
                 %{}
               )

      decoded = Jason.decode!(json)
      [row] = decoded["rows"]

      # proficiency_levels is preserved as a list of maps so the agent can
      # see which levels exist and pick which to edit.
      assert is_list(row["proficiency_levels"])
      assert Enum.any?(row["proficiency_levels"], fn lvl -> lvl["level"] == 3 end)
    end
  end

  describe "query_table tool: ids_json" do
    test "returns only rows matching the supplied ids, preserving order", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_with_levels_schema())

      {:ok, [py, el, rb]} =
        DataTable.add_rows(
          sid,
          [
            %{skill_name: "Python", proficiency_levels: [%{level: 1}]},
            %{skill_name: "Elixir", proficiency_levels: [%{level: 1}]},
            %{skill_name: "Ruby", proficiency_levels: [%{level: 1}]}
          ],
          table: "library"
        )

      execute = query_table_execute(sid)

      # Note reversed order to verify ordering follows ids list, not insertion.
      assert {:ok, json} =
               execute.(
                 %{
                   table: "library",
                   ids_json: Jason.encode!([rb.id, py.id])
                 },
                 %{}
               )

      decoded = Jason.decode!(json)
      assert length(decoded["rows"]) == 2
      [first, second] = decoded["rows"]
      assert first["skill_name"] == "Ruby"
      assert second["skill_name"] == "Python"
      # Did not pull Elixir.
      refute Enum.any?(decoded["rows"], &(&1["skill_name"] == "Elixir"))
      # children visible
      assert is_list(first["proficiency_levels"])
      _ = el
    end

    test "ids_json wins over filter_field/filter_value", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_with_levels_schema())

      {:ok, [py, _el]} =
        DataTable.add_rows(
          sid,
          [%{skill_name: "Python"}, %{skill_name: "Elixir"}],
          table: "library"
        )

      execute = query_table_execute(sid)

      assert {:ok, json} =
               execute.(
                 %{
                   table: "library",
                   ids_json: Jason.encode!([py.id]),
                   filter_field: "skill_name",
                   filter_value: "Elixir"
                 },
                 %{}
               )

      [row] = Jason.decode!(json)["rows"]
      assert row["skill_name"] == "Python"
    end

    test "errors on malformed ids_json", %{session_id: sid} do
      DataTable.ensure_started(sid)
      execute = query_table_execute(sid)

      assert {:error, msg} = execute.(%{ids_json: "not json"}, %{})
      assert msg =~ "ids_json is not valid JSON"
    end

    test "errors on non-string id elements", %{session_id: sid} do
      DataTable.ensure_started(sid)
      execute = query_table_execute(sid)

      assert {:error, msg} = execute.(%{ids_json: ~s([1,2,3])}, %{})
      assert msg =~ "string ids"
    end
  end

  describe "prompt_sections/2 with children" do
    test "renders child columns line for active table with children_key", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_with_levels_schema())
      :ok = DataTable.set_active_table(sid, "library")

      [section] = Plugin.prompt_sections([], %{session_id: sid})

      assert section.body =~ "child columns (proficiency_levels[]):"
      assert section.body =~ "level, level_name, level_description"
      assert section.body =~ "child key: level"
    end
  end
end
