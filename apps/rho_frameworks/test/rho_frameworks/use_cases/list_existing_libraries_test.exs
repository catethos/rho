defmodule RhoFrameworks.UseCases.ListExistingLibrariesTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.{Library, Repo, Scope}
  alias RhoFrameworks.UseCases.ListExistingLibraries

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "ListExisting Test Org",
      slug: "list-existing-#{System.unique_integer([:positive])}"
    })

    session_id = "sess-list-existing-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        Rho.Stdlib.DataTable.stop(session_id)
      catch
        _, _ -> :ok
      end
    end)

    scope = %Scope{organization_id: org_id, session_id: session_id}
    %{scope: scope, org_id: org_id}
  end

  describe "describe/0" do
    test "advertises the instant cost hint" do
      assert %{id: :list_existing_libraries, cost_hint: :instant} =
               ListExistingLibraries.describe()
    end
  end

  describe "run/2" do
    test "returns skip_reason when org has no libraries", %{scope: scope} do
      assert {:ok, %{matches: [], skip_reason: reason}} = ListExistingLibraries.run(%{}, scope)
      assert is_binary(reason)
      assert reason =~ "No existing frameworks"
    end

    test "lists draft libraries with skill_count + updated_at", %{scope: scope, org_id: org_id} do
      {:ok, lib} = Library.create_library(org_id, %{name: "My Framework"})
      {:ok, _} = Library.upsert_skill(lib.id, %{name: "Skill A", category: "Eng", cluster: "T"})
      {:ok, _} = Library.upsert_skill(lib.id, %{name: "Skill B", category: "Eng", cluster: "T"})

      assert {:ok, %{matches: [match], skip_reason: nil}} = ListExistingLibraries.run(%{}, scope)
      assert match.id == lib.id
      assert match.name == "My Framework"
      assert match.skill_count == 2
      assert is_binary(match.updated_at)
    end

    test "excludes immutable libraries (templates)", %{scope: scope, org_id: org_id} do
      {:ok, draft} = Library.create_library(org_id, %{name: "Draft Framework"})

      {:ok, _template} =
        %RhoFrameworks.Frameworks.Library{}
        |> RhoFrameworks.Frameworks.Library.changeset(%{
          name: "Frozen Template",
          organization_id: org_id,
          immutable: true
        })
        |> Repo.insert()

      assert {:ok, %{matches: matches, skip_reason: nil}} =
               ListExistingLibraries.run(%{}, scope)

      ids = Enum.map(matches, & &1.id)
      assert draft.id in ids
      refute Enum.any?(matches, fn m -> m.name == "Frozen Template" end)
    end
  end
end
