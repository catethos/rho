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
               heading: "Active data tables",
               kind: :reference
             } = section

      assert section.body =~ "- main (0 rows)"
      assert section.body =~ "- library (0 rows)"
      # No table line carries the active marker.
      refute section.body =~ "rows) ← currently open"
    end

    test "marks the active table when set", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())
      :ok = DataTable.set_active_table(sid, "library")

      [section] = Plugin.prompt_sections([], %{session_id: sid})
      lines = String.split(section.body, "\n")

      assert Enum.any?(lines, &(&1 == "- library (0 rows) ← currently open in panel"))
      assert Enum.any?(lines, &(&1 == "- main (0 rows)"))
    end

    test "row_count reflects current rows", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())

      {:ok, _} =
        DataTable.add_rows(sid, [%{skill_name: "Python"}, %{skill_name: "Elixir"}],
          table: "library"
        )

      [section] = Plugin.prompt_sections([], %{session_id: sid})

      assert section.body =~ "- library (2 rows)"
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

      assert section.body =~ "Selected (2):"
      assert section.body =~ "skill_name=\"Python\""
      assert section.body =~ "skill_name=\"Elixir\""
    end

    test "non-active table selections collapse to count only", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())

      {:ok, [r]} = DataTable.add_rows(sid, [%{skill_name: "Python"}], table: "library")

      :ok = DataTable.set_active_table(sid, "main")
      :ok = DataTable.set_selection(sid, "library", [r.id])

      [section] = Plugin.prompt_sections([], %{session_id: sid})

      assert section.body =~ "Selected (1)"
      refute section.body =~ "skill_name=\"Python\""
    end

    test "truncates past the 10-row preview cap", %{session_id: sid} do
      DataTable.ensure_started(sid)
      :ok = DataTable.ensure_table(sid, "library", library_schema())

      rows = for i <- 1..12, do: %{skill_name: "Skill #{i}"}

      {:ok, inserted} = DataTable.add_rows(sid, rows, table: "library")
      :ok = DataTable.set_active_table(sid, "library")
      :ok = DataTable.set_selection(sid, "library", Enum.map(inserted, & &1.id))

      [section] = Plugin.prompt_sections([], %{session_id: sid})

      assert section.body =~ "Selected (12):"
      assert section.body =~ "… + 2 more selected"
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
end
