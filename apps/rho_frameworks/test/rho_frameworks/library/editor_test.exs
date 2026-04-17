defmodule RhoFrameworks.Library.EditorTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.Library, as: LibraryCtx
  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.Runtime
  alias RhoFrameworks.Repo

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "Editor Test Org",
      slug: "editor-test-#{System.unique_integer([:positive])}"
    })

    session_id = "sess-editor-#{System.unique_integer([:positive])}"
    on_exit(fn -> DataTable.stop(session_id) end)

    agent_rt = %Runtime{
      mode: :agent,
      organization_id: org_id,
      session_id: session_id,
      parent_agent_id: "agent-test"
    }

    flow_rt =
      Runtime.new_flow(
        organization_id: org_id,
        session_id: session_id,
        execution_id: "flow-test-1"
      )

    %{org_id: org_id, session_id: session_id, agent_rt: agent_rt, flow_rt: flow_rt}
  end

  # -------------------------------------------------------------------
  # table_name / table_spec
  # -------------------------------------------------------------------

  describe "table_name/1" do
    test "prefixes with library:" do
      assert Editor.table_name("Engineering") == "library:Engineering"
    end
  end

  describe "table_spec/1" do
    test "returns complete spec" do
      spec = Editor.table_spec("Engineering")

      assert spec.name == "library:Engineering"
      assert spec.schema_key == :skill_library
      assert spec.mode_label == "Skill Library — Engineering"
      assert %Rho.Stdlib.DataTable.Schema{} = spec.schema
    end
  end

  # -------------------------------------------------------------------
  # create/2
  # -------------------------------------------------------------------

  describe "create/2" do
    test "creates library and initializes DataTable in agent mode", %{agent_rt: rt} do
      assert {:ok, %{library: lib, table: spec}} =
               Editor.create(%{name: "My Skills", description: "Test"}, rt)

      assert lib.name == "My Skills"
      assert lib.organization_id == rt.organization_id
      assert spec.name == "library:My Skills"

      # DataTable should be initialized
      assert DataTable.get_rows(rt.session_id, table: "library:My Skills") == []
    end

    test "creates library and initializes DataTable in flow mode", %{flow_rt: rt} do
      assert {:ok, %{library: lib, table: spec}} =
               Editor.create(%{name: "Flow Skills"}, rt)

      assert lib.name == "Flow Skills"
      assert spec.name == "library:Flow Skills"

      # Same DB result regardless of mode
      assert LibraryCtx.get_library(rt.organization_id, lib.id) != nil
    end

    test "defaults description to empty string when not provided", %{agent_rt: rt} do
      assert {:ok, %{library: lib}} = Editor.create(%{name: "No Desc"}, rt)
      # Library context stores nil when description is empty string
      assert lib.description in [nil, ""]
    end
  end

  # -------------------------------------------------------------------
  # read_rows/2
  # -------------------------------------------------------------------

  describe "read_rows/2" do
    test "returns rows from a populated table", %{agent_rt: rt, session_id: sid} do
      tbl = "library:ReadTest"

      :ok =
        DataTable.ensure_table(
          sid,
          tbl,
          RhoFrameworks.DataTableSchemas.library_schema()
        )

      {:ok, _} =
        DataTable.add_rows(
          sid,
          [%{category: "Dev", cluster: "Lang", skill_name: "Elixir", skill_description: "BEAM"}],
          table: tbl
        )

      assert {:ok, [row]} = Editor.read_rows(%{table_name: tbl}, rt)
      assert row.skill_name == "Elixir"
    end

    test "returns error when table server not running", %{agent_rt: rt} do
      assert {:error, {:not_running, "library:Ghost"}} =
               Editor.read_rows(%{table_name: "library:Ghost"}, rt)
    end
  end

  # -------------------------------------------------------------------
  # save_table/2
  # -------------------------------------------------------------------

  describe "save_table/2" do
    setup %{org_id: org_id, session_id: sid, agent_rt: rt} do
      {:ok, lib} =
        LibraryCtx.create_library(org_id, %{name: "SaveTest", description: "For save tests"})

      tbl = Editor.table_name(lib.name)
      :ok = DataTable.ensure_table(sid, tbl, RhoFrameworks.DataTableSchemas.library_schema())

      {:ok, _} =
        DataTable.add_rows(
          sid,
          [
            %{
              category: "Dev",
              cluster: "Lang",
              skill_name: "Elixir",
              skill_description: "Functional"
            },
            %{
              category: "Dev",
              cluster: "Lang",
              skill_name: "Go",
              skill_description: "Systems"
            }
          ],
          table: tbl
        )

      %{lib: lib, tbl: tbl, rt: rt}
    end

    test "persists DataTable rows to library", %{lib: lib, tbl: tbl, rt: rt} do
      assert {:ok, %{saved_count: 2, library: _lib, draft_library_id: _}} =
               Editor.save_table(%{library_id: lib.id, table_name: tbl}, rt)

      skills = LibraryCtx.list_skills(lib.id)
      names = Enum.map(skills, & &1.name) |> Enum.sort()
      assert names == ["Elixir", "Go"]
    end

    test "uses default library when library_id is nil", %{tbl: tbl, rt: rt} do
      assert {:ok, %{saved_count: 2}} =
               Editor.save_table(%{library_id: nil, table_name: tbl}, rt)
    end

    test "returns error for empty table", %{org_id: org_id, session_id: sid, rt: rt} do
      {:ok, lib} = LibraryCtx.create_library(org_id, %{name: "EmptyLib"})
      tbl = Editor.table_name(lib.name)
      :ok = DataTable.ensure_table(sid, tbl, RhoFrameworks.DataTableSchemas.library_schema())

      assert {:error, {:empty_table, ^tbl}} =
               Editor.save_table(%{library_id: lib.id, table_name: tbl}, rt)
    end

    test "returns error when DataTable not running", %{org_id: org_id} do
      {:ok, lib} = LibraryCtx.create_library(org_id, %{name: "NoServerLib"})
      tbl = Editor.table_name(lib.name)

      # Use a fresh session where no DataTable server has been started
      fresh_rt = %Runtime{
        mode: :agent,
        organization_id: org_id,
        session_id: "sess-no-server-#{System.unique_integer([:positive])}",
        parent_agent_id: "agent-test"
      }

      assert {:error, {:not_running, ^tbl}} =
               Editor.save_table(%{library_id: lib.id, table_name: tbl}, fresh_rt)
    end

    test "works identically in flow mode", %{lib: lib, tbl: tbl, flow_rt: flow_rt} do
      assert {:ok, %{saved_count: 2}} =
               Editor.save_table(%{library_id: lib.id, table_name: tbl}, flow_rt)
    end
  end

  # -------------------------------------------------------------------
  # append_rows/2
  # -------------------------------------------------------------------

  describe "append_rows/2" do
    setup %{session_id: sid} do
      tbl = "library:AppendTest"

      :ok =
        DataTable.ensure_table(
          sid,
          tbl,
          RhoFrameworks.DataTableSchemas.library_schema()
        )

      %{tbl: tbl}
    end

    test "appends rows and returns count", %{agent_rt: rt, tbl: tbl} do
      rows = [
        %{category: "Dev", cluster: "Lang", skill_name: "Elixir", skill_description: "BEAM"},
        %{category: "Dev", cluster: "Lang", skill_name: "Go", skill_description: "Systems"}
      ]

      assert {:ok, %{count: 2}} = Editor.append_rows(%{table_name: tbl, rows: rows}, rt)

      assert {:ok, fetched} = Editor.read_rows(%{table_name: tbl}, rt)
      assert length(fetched) == 2
    end

    test "returns error when table server not running", %{org_id: org_id} do
      fresh_rt = %Runtime{
        mode: :agent,
        organization_id: org_id,
        session_id: "sess-no-server-append-#{System.unique_integer([:positive])}",
        parent_agent_id: "agent-test"
      }

      assert {:error, {:not_running, "library:Ghost"}} =
               Editor.append_rows(
                 %{table_name: "library:Ghost", rows: [%{skill_name: "X"}]},
                 fresh_rt
               )
    end
  end

  # -------------------------------------------------------------------
  # replace_rows/2
  # -------------------------------------------------------------------

  describe "replace_rows/2" do
    setup %{session_id: sid} do
      tbl = "library:ReplaceTest"

      :ok =
        DataTable.ensure_table(
          sid,
          tbl,
          RhoFrameworks.DataTableSchemas.library_schema()
        )

      {:ok, _} =
        DataTable.add_rows(
          sid,
          [%{category: "Old", cluster: "X", skill_name: "OldSkill", skill_description: "Gone"}],
          table: tbl
        )

      %{tbl: tbl}
    end

    test "replaces all rows", %{agent_rt: rt, tbl: tbl} do
      new_rows = [
        %{category: "New", cluster: "Y", skill_name: "NewSkill", skill_description: "Fresh"}
      ]

      assert {:ok, %{count: 1}} = Editor.replace_rows(%{table_name: tbl, rows: new_rows}, rt)

      assert {:ok, [row]} = Editor.read_rows(%{table_name: tbl}, rt)
      assert row.skill_name == "NewSkill"
    end

    test "works identically in flow mode", %{flow_rt: rt, tbl: tbl} do
      new_rows = [
        %{category: "Flow", cluster: "Z", skill_name: "FlowSkill", skill_description: "Test"}
      ]

      assert {:ok, %{count: 1}} = Editor.replace_rows(%{table_name: tbl, rows: new_rows}, rt)
    end
  end

  # -------------------------------------------------------------------
  # apply_proficiency_levels/2
  # -------------------------------------------------------------------

  describe "apply_proficiency_levels/2" do
    setup %{session_id: sid} do
      tbl = "library:ProfTest"

      :ok =
        DataTable.ensure_table(
          sid,
          tbl,
          RhoFrameworks.DataTableSchemas.library_schema()
        )

      {:ok, _} =
        DataTable.add_rows(
          sid,
          [
            %{
              category: "Dev",
              cluster: "Lang",
              skill_name: "Elixir",
              skill_description: "BEAM",
              proficiency_levels: []
            },
            %{
              category: "Dev",
              cluster: "Lang",
              skill_name: "Go",
              skill_description: "Systems",
              proficiency_levels: []
            }
          ],
          table: tbl
        )

      %{tbl: tbl}
    end

    test "updates matching skills and reports skipped", %{agent_rt: rt, tbl: tbl} do
      skill_levels = [
        %{
          "skill_name" => "Elixir",
          "levels" => [
            %{"level" => 1, "level_name" => "Novice", "level_description" => "Basics"}
          ]
        },
        %{
          "skill_name" => "Rust",
          "levels" => [
            %{"level" => 1, "level_name" => "Novice", "level_description" => "Basics"}
          ]
        }
      ]

      assert {:ok, %{updated_count: 1, skipped: ["Rust"]}} =
               Editor.apply_proficiency_levels(%{table_name: tbl, skill_levels: skill_levels}, rt)

      # Verify the update persisted
      assert {:ok, rows} = Editor.read_rows(%{table_name: tbl}, rt)
      elixir_row = Enum.find(rows, &(&1.skill_name == "Elixir"))
      assert length(elixir_row.proficiency_levels) == 1
    end

    test "returns error when no skills match", %{agent_rt: rt, tbl: tbl} do
      skill_levels = [
        %{
          "skill_name" => "Rust",
          "levels" => [%{"level" => 1, "level_name" => "N", "level_description" => "D"}]
        }
      ]

      assert {:error, {:no_matches, ["Rust"]}} =
               Editor.apply_proficiency_levels(%{table_name: tbl, skill_levels: skill_levels}, rt)
    end

    test "returns error when table server not running", %{org_id: org_id} do
      fresh_rt = %Runtime{
        mode: :agent,
        organization_id: org_id,
        session_id: "sess-no-server-prof-#{System.unique_integer([:positive])}",
        parent_agent_id: "agent-test"
      }

      assert {:error, {:not_running, "library:Ghost"}} =
               Editor.apply_proficiency_levels(
                 %{
                   table_name: "library:Ghost",
                   skill_levels: [%{"skill_name" => "X", "levels" => []}]
                 },
                 fresh_rt
               )
    end

    test "works in flow mode", %{flow_rt: rt, tbl: tbl} do
      skill_levels = [
        %{
          "skill_name" => "Go",
          "levels" => [
            %{"level" => 1, "level_name" => "Novice", "level_description" => "Basics"},
            %{"level" => 2, "level_name" => "Advanced", "level_description" => "Expert"}
          ]
        }
      ]

      assert {:ok, %{updated_count: 1, skipped: []}} =
               Editor.apply_proficiency_levels(%{table_name: tbl, skill_levels: skill_levels}, rt)
    end
  end
end
