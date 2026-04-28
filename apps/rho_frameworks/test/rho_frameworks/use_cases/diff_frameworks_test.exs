defmodule RhoFrameworks.UseCases.DiffFrameworksTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{Library, Repo, Scope, Workbench}
  alias RhoFrameworks.UseCases.DiffFrameworks

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "DiffFrameworks Test Org",
      slug: "diff-frameworks-#{System.unique_integer([:positive])}"
    })

    session_id = "sess-diff-#{System.unique_integer([:positive])}"
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
      assert %{id: :diff_frameworks, cost_hint: :instant} = DiffFrameworks.describe()
    end
  end

  describe "run/2" do
    test "errors when either library_id is missing", %{scope: scope} do
      assert {:error, :missing_library_id_a} = DiffFrameworks.run(%{}, scope)

      assert {:error, :missing_library_id_b} =
               DiffFrameworks.run(%{library_id_a: "abc"}, scope)
    end

    test "errors when both ids are equal", %{scope: scope} do
      assert {:error, :duplicate_library_ids} =
               DiffFrameworks.run(%{library_id_a: "x", library_id_b: "x"}, scope)
    end

    test "errors when a library does not exist for the org", %{scope: scope} do
      assert {:error, {:library_not_found, _}} =
               DiffFrameworks.run(
                 %{library_id_a: Ecto.UUID.generate(), library_id_b: Ecto.UUID.generate()},
                 scope
               )
    end

    test "writes conflict pairs into the combine_preview table and returns counts",
         %{scope: scope, org_id: org_id, session_id: session_id} do
      {:ok, lib_a} = Library.create_library(org_id, %{name: "Lib A"})
      {:ok, lib_b} = Library.create_library(org_id, %{name: "Lib B"})

      # Shared skill name across libs → slug-prefix conflict.
      {:ok, _} =
        Library.upsert_skill(lib_a.id, %{name: "API Design", category: "Eng", cluster: "Web"})

      {:ok, _} =
        Library.upsert_skill(lib_b.id, %{
          name: "API Design",
          category: "Eng",
          cluster: "Backend"
        })

      # Unique skill in each — no conflict.
      {:ok, _} =
        Library.upsert_skill(lib_a.id, %{name: "Caching", category: "Eng", cluster: "Web"})

      {:ok, _} =
        Library.upsert_skill(lib_b.id, %{
          name: "Database Modeling",
          category: "Eng",
          cluster: "Backend"
        })

      assert {:ok, summary} =
               DiffFrameworks.run(
                 %{library_id_a: lib_a.id, library_id_b: lib_b.id},
                 scope
               )

      assert summary.table_name == Workbench.combine_preview_table()
      assert summary.conflict_count >= 1
      assert summary.total == 4

      rows = DataTable.get_rows(session_id, table: Workbench.combine_preview_table())
      assert is_list(rows)
      assert length(rows) == summary.conflict_count

      # Every row starts unresolved and carries both skill ids.
      for row <- rows do
        assert (row[:resolution] || row["resolution"]) == "unresolved"
        assert is_binary(row[:skill_a_id] || row["skill_a_id"])
        assert is_binary(row[:skill_b_id] || row["skill_b_id"])
      end
    end
  end
end
