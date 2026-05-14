defmodule RhoFrameworks.UseCases.LoadExistingFrameworkTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{Library, Repo, Scope}
  alias RhoFrameworks.UseCases.LoadExistingFramework

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "LoadExisting Test Org",
      slug: "load-existing-#{System.unique_integer([:positive])}"
    })

    session_id = "sess-load-existing-#{System.unique_integer([:positive])}"
    on_exit(fn -> DataTable.stop(session_id) end)

    scope = %Scope{
      organization_id: org_id,
      session_id: session_id,
      user_id: "user-test",
      source: :flow,
      reason: "wizard:create-framework"
    }

    %{scope: scope, org_id: org_id, session_id: session_id}
  end

  describe "describe/0" do
    test "advertises instant cost hint" do
      assert %{id: :load_existing_framework, cost_hint: :instant} =
               LoadExistingFramework.describe()
    end
  end

  describe "run/2" do
    test "errors when library_id is missing", %{scope: scope} do
      assert {:error, :missing_library_id} = LoadExistingFramework.run(%{}, scope)
      assert {:error, :missing_library_id} = LoadExistingFramework.run(%{library_id: ""}, scope)
    end

    test "errors when library does not exist for org", %{scope: scope} do
      assert {:error, :library_not_found} =
               LoadExistingFramework.run(%{library_id: Ecto.UUID.generate()}, scope)
    end

    test "hydrates the library:<name> table and reports counts", %{
      scope: scope,
      org_id: org_id,
      session_id: session_id
    } do
      {:ok, lib} = Library.create_library(org_id, %{name: "Backend Eng"})

      {:ok, _} =
        Library.upsert_skill(lib.id, %{
          name: "API Design",
          category: "Eng",
          cluster: "Backend",
          description: "Designs APIs"
        })

      {:ok, _} =
        Library.upsert_skill(lib.id, %{
          name: "Database Modeling",
          category: "Eng",
          cluster: "Backend",
          description: "Models data"
        })

      assert {:ok, summary} = LoadExistingFramework.run(%{library_id: lib.id}, scope)

      assert summary.library_id == lib.id
      assert summary.library_name == "Backend Eng"
      assert summary.table_name == "library:Backend Eng"
      assert summary.skill_count == 2
      assert summary.role_count == 0

      rows = DataTable.get_rows(session_id, table: "library:Backend Eng")
      assert is_list(rows)
      assert match?([_, _], rows)

      names =
        rows
        |> Enum.map(fn r -> r[:skill_name] || r["skill_name"] end)
        |> MapSet.new()

      assert MapSet.equal?(names, MapSet.new(["API Design", "Database Modeling"]))
    end

    test "has_proficiency=false when no skills have proficiency_levels", %{
      scope: scope,
      org_id: org_id
    } do
      {:ok, lib} = Library.create_library(org_id, %{name: "NoProf Lib"})
      {:ok, _} = Library.upsert_skill(lib.id, %{name: "S1", category: "C", cluster: "K"})

      assert {:ok, summary} = LoadExistingFramework.run(%{library_id: lib.id}, scope)
      refute summary.has_proficiency
    end

    test "has_proficiency=true when every skill has proficiency_levels", %{
      scope: scope,
      org_id: org_id
    } do
      {:ok, lib} = Library.create_library(org_id, %{name: "WithProf Lib"})

      levels = [%{level: 1, level_name: "Novice", level_description: "Just starting."}]

      {:ok, _} =
        Library.upsert_skill(lib.id, %{
          name: "S1",
          category: "C",
          cluster: "K",
          proficiency_levels: levels
        })

      {:ok, _} =
        Library.upsert_skill(lib.id, %{
          name: "S2",
          category: "C",
          cluster: "K",
          proficiency_levels: levels
        })

      assert {:ok, summary} = LoadExistingFramework.run(%{library_id: lib.id}, scope)
      assert summary.has_proficiency
    end

    test "has_proficiency=false when only some skills have proficiency_levels", %{
      scope: scope,
      org_id: org_id
    } do
      {:ok, lib} = Library.create_library(org_id, %{name: "MixedProf Lib"})

      levels = [%{level: 1, level_name: "Novice", level_description: "Just starting."}]

      {:ok, _} =
        Library.upsert_skill(lib.id, %{
          name: "WithLevels",
          category: "C",
          cluster: "K",
          proficiency_levels: levels
        })

      {:ok, _} =
        Library.upsert_skill(lib.id, %{
          name: "WithoutLevels",
          category: "C",
          cluster: "K"
        })

      assert {:ok, summary} = LoadExistingFramework.run(%{library_id: lib.id}, scope)
      refute summary.has_proficiency
    end

    test "accepts string keys", %{scope: scope, org_id: org_id} do
      {:ok, lib} = Library.create_library(org_id, %{name: "StringKey Lib"})

      {:ok, _} =
        Library.upsert_skill(lib.id, %{name: "S", category: "C", cluster: "K"})

      assert {:ok, %{library_id: id}} =
               LoadExistingFramework.run(%{"library_id" => lib.id}, scope)

      assert id == lib.id
    end
  end
end
