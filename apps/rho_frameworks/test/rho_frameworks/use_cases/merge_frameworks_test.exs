defmodule RhoFrameworks.UseCases.MergeFrameworksTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{Library, Repo, Scope, Workbench}
  alias RhoFrameworks.UseCases.{DiffFrameworks, MergeFrameworks}

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "MergeFrameworks Test Org",
      slug: "merge-frameworks-#{System.unique_integer([:positive])}"
    })

    session_id = "sess-merge-#{System.unique_integer([:positive])}"
    on_exit(fn -> DataTable.stop(session_id) end)

    scope = %Scope{
      organization_id: org_id,
      session_id: session_id,
      user_id: "user-test",
      source: :flow
    }

    %{scope: scope, org_id: org_id, session_id: session_id}
  end

  describe "describe/0" do
    test "advertises instant cost hint" do
      assert %{id: :merge_frameworks, cost_hint: :instant} = MergeFrameworks.describe()
    end
  end

  describe "run/2" do
    test "errors when required input is missing", %{scope: scope} do
      assert {:error, :missing_library_id_a} = MergeFrameworks.run(%{}, scope)

      assert {:error, :missing_library_id_b} =
               MergeFrameworks.run(%{library_id_a: "x"}, scope)

      assert {:error, :missing_new_name} =
               MergeFrameworks.run(%{library_id_a: "x", library_id_b: "y"}, scope)
    end

    test "merges two libraries with user resolutions and persists the result",
         %{scope: scope, org_id: org_id} do
      {:ok, lib_a} = Library.create_library(org_id, %{name: "Source A"})
      {:ok, lib_b} = Library.create_library(org_id, %{name: "Source B"})

      {:ok, _} =
        Library.upsert_skill(lib_a.id, %{
          name: "API Design",
          category: "Eng",
          cluster: "Web",
          description: "from A"
        })

      {:ok, _} =
        Library.upsert_skill(lib_b.id, %{
          name: "API Design",
          category: "Eng",
          cluster: "Backend",
          description: "from B"
        })

      {:ok, _} =
        Library.upsert_skill(lib_a.id, %{name: "Caching", category: "Eng", cluster: "Web"})

      {:ok, _} =
        Library.upsert_skill(lib_b.id, %{
          name: "Database Modeling",
          category: "Eng",
          cluster: "Backend"
        })

      # Stage the conflict rows then mark them resolved.
      {:ok, _} =
        DiffFrameworks.run(%{library_id_a: lib_a.id, library_id_b: lib_b.id}, scope)

      rows = DataTable.get_rows(scope.session_id, table: Workbench.combine_preview_table())

      Process.put(:rho_source, :user)

      changes =
        Enum.map(rows, fn row ->
          %{id: row[:id], field: :resolution, value: "merge_a"}
        end)

      :ok =
        DataTable.update_cells(scope.session_id, changes,
          table: Workbench.combine_preview_table()
        )

      assert {:ok, summary} =
               MergeFrameworks.run(
                 %{
                   library_id_a: lib_a.id,
                   library_id_b: lib_b.id,
                   new_name: "Merged Eng"
                 },
                 scope
               )

      assert is_binary(summary.library_id)
      assert summary.library_name == "Merged Eng"
      assert summary.table_name == "library:Merged Eng"
      assert summary.skill_count >= 1

      # The merged library is persisted to Ecto.
      merged = Library.get_library(org_id, summary.library_id)
      assert merged.name == "Merged Eng"
      assert merged.immutable == false

      # And hydrated into the session for the :save step.
      session_rows =
        DataTable.get_rows(scope.session_id, table: "library:Merged Eng")

      assert is_list(session_rows)
      assert length(session_rows) == summary.skill_count
    end

    test "keep_both preserves both skill names with a disambiguation suffix",
         %{scope: scope, org_id: org_id} do
      {:ok, lib_a} = Library.create_library(org_id, %{name: "Source A"})
      {:ok, lib_b} = Library.create_library(org_id, %{name: "Source B"})

      {:ok, _} =
        Library.upsert_skill(lib_a.id, %{
          name: "API Design",
          category: "Eng",
          cluster: "Web",
          description: "REST/HTTP design from A"
        })

      {:ok, _} =
        Library.upsert_skill(lib_b.id, %{
          name: "API Design",
          category: "Eng",
          cluster: "Backend",
          description: "GraphQL/RPC design from B"
        })

      {:ok, _} =
        DiffFrameworks.run(%{library_id_a: lib_a.id, library_id_b: lib_b.id}, scope)

      rows = DataTable.get_rows(scope.session_id, table: Workbench.combine_preview_table())

      Process.put(:rho_source, :user)

      changes =
        Enum.map(rows, fn row ->
          %{id: row[:id], field: :resolution, value: "keep_both"}
        end)

      :ok =
        DataTable.update_cells(scope.session_id, changes,
          table: Workbench.combine_preview_table()
        )

      assert {:ok, summary} =
               MergeFrameworks.run(
                 %{
                   library_id_a: lib_a.id,
                   library_id_b: lib_b.id,
                   new_name: "Merged Both"
                 },
                 scope
               )

      # Both skills survive — keep_both must NOT collapse via slug-dedup.
      assert summary.skill_count == 2

      merged_skills = Library.list_skills(summary.library_id)
      names = Enum.map(merged_skills, & &1.name) |> Enum.sort()

      # One keeps the original name, the other gets a "(2)" suffix.
      assert "API Design" in names
      assert Enum.any?(names, &String.match?(&1, ~r/^API Design \(\d+\)$/))
    end
  end
end
