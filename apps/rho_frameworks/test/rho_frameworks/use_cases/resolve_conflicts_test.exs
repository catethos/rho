defmodule RhoFrameworks.UseCases.ResolveConflictsTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{DataTableSchemas, Scope, Workbench}
  alias RhoFrameworks.UseCases.ResolveConflicts

  setup do
    org_id = Ecto.UUID.generate()
    session_id = "sess-resolve-#{System.unique_integer([:positive])}"
    on_exit(fn -> DataTable.stop(session_id) end)

    DataTable.ensure_started(session_id)

    DataTable.ensure_table(
      session_id,
      Workbench.combine_preview_table(),
      DataTableSchemas.combine_preview_schema()
    )

    scope = %Scope{
      organization_id: org_id,
      session_id: session_id,
      user_id: "user-test",
      source: :flow
    }

    %{scope: scope, session_id: session_id}
  end

  defp seed_conflict(session_id, attrs) do
    base = %{
      category: "Eng",
      confidence: "high",
      skill_a_id: "a-#{System.unique_integer([:positive])}",
      skill_a_name: "API",
      skill_a_source: "Lib A",
      skill_b_id: "b-#{System.unique_integer([:positive])}",
      skill_b_name: "API",
      skill_b_source: "Lib B",
      resolution: "unresolved"
    }

    DataTable.add_rows(session_id, [Map.merge(base, attrs)],
      table: Workbench.combine_preview_table()
    )
  end

  describe "run/2" do
    test "succeeds with zero rows (no conflicts to resolve)", %{scope: scope} do
      assert {:ok, %{resolved_count: 0, unresolved_count: 0}} =
               ResolveConflicts.run(%{}, scope)
    end

    test "errors with the unresolved count when any row is unresolved",
         %{scope: scope, session_id: sid} do
      {:ok, _} = seed_conflict(sid, %{resolution: "merge_a"})
      {:ok, _} = seed_conflict(sid, %{resolution: "unresolved"})
      {:ok, _} = seed_conflict(sid, %{resolution: "unresolved"})

      assert {:error, {:unresolved, 2}} = ResolveConflicts.run(%{}, scope)
    end

    test "succeeds when every row carries an accepted resolution",
         %{scope: scope, session_id: sid} do
      {:ok, _} = seed_conflict(sid, %{resolution: "merge_a"})
      {:ok, _} = seed_conflict(sid, %{resolution: "merge_b"})
      {:ok, _} = seed_conflict(sid, %{resolution: "keep_both"})

      assert {:ok, %{resolved_count: 3, unresolved_count: 0}} =
               ResolveConflicts.run(%{}, scope)
    end
  end
end
