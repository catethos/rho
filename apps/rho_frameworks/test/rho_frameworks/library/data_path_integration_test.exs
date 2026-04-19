defmodule RhoFrameworks.Library.DataPathIntegrationTest do
  @moduledoc """
  Integration tests that exercise the full data path through composable
  primitives, verifying that atom-keyed DataTable rows survive through
  Proficiency prompt building and Editor.save_table persistence.
  """
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.Library, as: LibraryCtx
  alias RhoFrameworks.Library.{Editor, Proficiency}
  alias RhoFrameworks.Runtime
  alias RhoFrameworks.Repo

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "Integration Test Org",
      slug: "integ-test-#{System.unique_integer([:positive])}"
    })

    session_id = "sess-integ-#{System.unique_integer([:positive])}"
    DataTable.ensure_started(session_id)
    on_exit(fn -> DataTable.stop(session_id) end)

    rt =
      Runtime.new_flow(
        organization_id: org_id,
        session_id: session_id,
        execution_id: "flow-integ-1"
      )

    tbl = "library:IntegTest"
    :ok = DataTable.ensure_table(session_id, tbl, DataTableSchemas.library_schema())

    %{org_id: org_id, session_id: session_id, rt: rt, tbl: tbl}
  end

  # -------------------------------------------------------------------
  # DataTable (atom keys) → Proficiency.build_prompt
  # -------------------------------------------------------------------

  describe "DataTable atom-key rows → Proficiency.build_prompt" do
    test "skill names from atom-keyed DataTable rows appear in prompt text", ctx do
      # Insert rows with atom keys (as DataTable produces)
      {:ok, _} =
        DataTable.add_rows(
          ctx.session_id,
          [
            %{
              category: "Engineering",
              cluster: "Languages",
              skill_name: "Elixir",
              skill_description: "Functional programming on BEAM"
            },
            %{
              category: "Engineering",
              cluster: "Languages",
              skill_name: "TypeScript",
              skill_description: "Typed JavaScript"
            },
            %{
              category: "Data",
              cluster: "Analytics",
              skill_name: "SQL",
              skill_description: "Database querying"
            }
          ],
          table: ctx.tbl
        )

      # Read rows back through Editor (same path FlowLive uses)
      {:ok, rows} = Editor.read_rows(%{table_name: ctx.tbl}, ctx.rt)
      assert length(rows) == 3

      # Group by category and build prompts (same path Proficiency.start_fanout uses)
      by_category = Enum.group_by(rows, fn r -> r[:category] || r["category"] end)

      for {category, cat_skills} <- by_category do
        prompt =
          Proficiency.build_prompt(%{
            category: category,
            skills: cat_skills,
            levels: 5,
            table_name: ctx.tbl
          })

        # Every skill name in this category must appear in the prompt
        for skill <- cat_skills do
          skill_name = skill[:skill_name] || skill["skill_name"]
          assert prompt =~ skill_name, "Skill '#{skill_name}' missing from prompt for #{category}"
        end

        assert prompt =~ "Category: #{category}"
        assert prompt =~ ctx.tbl
      end
    end

    test "works with string-keyed maps too (LLM JSON decode path)", ctx do
      # Simulate LLM-generated maps (string keys)
      string_keyed_skills = [
        %{
          "category" => "DevOps",
          "cluster" => "CI/CD",
          "skill_name" => "Docker",
          "skill_description" => "Containerization"
        }
      ]

      prompt =
        Proficiency.build_prompt(%{
          category: "DevOps",
          skills: string_keyed_skills,
          levels: 3,
          table_name: ctx.tbl
        })

      assert prompt =~ "Docker"
      assert prompt =~ "CI/CD"
      assert prompt =~ "Containerization"
    end
  end

  # -------------------------------------------------------------------
  # DataTable rows with proficiency_levels → Editor.save_table → DB
  # -------------------------------------------------------------------

  describe "DataTable rows with proficiency_levels → Editor.save_table → DB" do
    test "proficiency_levels survive the full save path", ctx do
      {:ok, lib} =
        LibraryCtx.create_library(ctx.org_id, %{
          name: "IntegTest",
          description: "Integration test library"
        })

      levels = [
        %{level: 1, level_name: "Novice", level_description: "Basic understanding"},
        %{level: 2, level_name: "Practitioner", level_description: "Can apply independently"},
        %{level: 3, level_name: "Expert", level_description: "Deep mastery"}
      ]

      # Insert rows with proficiency_levels already populated (atom keys)
      {:ok, _} =
        DataTable.add_rows(
          ctx.session_id,
          [
            %{
              category: "Engineering",
              cluster: "Languages",
              skill_name: "Elixir",
              skill_description: "Functional programming on BEAM",
              proficiency_levels: levels
            },
            %{
              category: "Engineering",
              cluster: "Languages",
              skill_name: "Go",
              skill_description: "Systems programming",
              proficiency_levels: [
                %{level: 1, level_name: "Novice", level_description: "Basics"}
              ]
            }
          ],
          table: ctx.tbl
        )

      # Save to database through Editor
      assert {:ok, %{saved_count: 2}} =
               Editor.save_table(%{library_id: lib.id, table_name: ctx.tbl}, ctx.rt)

      # Verify skills in DB have proficiency_levels
      skills = LibraryCtx.list_skills(lib.id)
      assert length(skills) == 2

      elixir_skill = Enum.find(skills, &(&1.name == "Elixir"))
      assert elixir_skill != nil
      assert length(elixir_skill.proficiency_levels) == 3

      [l1, l2, l3] = Enum.sort_by(elixir_skill.proficiency_levels, & &1["level"])
      assert l1["level_name"] == "Novice"
      assert l2["level_name"] == "Practitioner"
      assert l3["level_name"] == "Expert"

      go_skill = Enum.find(skills, &(&1.name == "Go"))
      assert go_skill != nil
      assert length(go_skill.proficiency_levels) == 1
    end

    test "apply_proficiency_levels then save_table round-trip", ctx do
      {:ok, lib} =
        LibraryCtx.create_library(ctx.org_id, %{
          name: "IntegTest-RT",
          description: "Round-trip test"
        })

      # Step 1: Insert skeleton rows (no proficiency_levels)
      {:ok, _} =
        DataTable.add_rows(
          ctx.session_id,
          [
            %{
              category: "Data",
              cluster: "Analytics",
              skill_name: "SQL",
              skill_description: "Querying",
              proficiency_levels: []
            },
            %{
              category: "Data",
              cluster: "Analytics",
              skill_name: "Python",
              skill_description: "Scripting",
              proficiency_levels: []
            }
          ],
          table: ctx.tbl
        )

      # Step 2: Apply proficiency levels (simulating LLM output with string keys)
      skill_levels = [
        %{
          "skill_name" => "SQL",
          "levels" => [
            %{"level" => 1, "level_name" => "Novice", "level_description" => "Basic SELECT"},
            %{
              "level" => 2,
              "level_name" => "Intermediate",
              "level_description" => "JOINs and CTEs"
            }
          ]
        },
        %{
          "skill_name" => "Python",
          "levels" => [
            %{"level" => 1, "level_name" => "Beginner", "level_description" => "Scripts"}
          ]
        }
      ]

      assert {:ok, %{updated_count: 2, skipped: []}} =
               Editor.apply_proficiency_levels(
                 %{table_name: ctx.tbl, skill_levels: skill_levels},
                 ctx.rt
               )

      # Step 3: Save to DB
      assert {:ok, %{saved_count: 2}} =
               Editor.save_table(%{library_id: lib.id, table_name: ctx.tbl}, ctx.rt)

      # Step 4: Verify DB has proficiency levels
      skills = LibraryCtx.list_skills(lib.id)

      sql_skill = Enum.find(skills, &(&1.name == "SQL"))
      assert length(sql_skill.proficiency_levels) == 2

      python_skill = Enum.find(skills, &(&1.name == "Python"))
      assert length(python_skill.proficiency_levels) == 1
    end
  end
end
