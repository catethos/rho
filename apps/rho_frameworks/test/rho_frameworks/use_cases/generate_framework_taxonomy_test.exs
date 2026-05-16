defmodule RhoFrameworks.UseCases.GenerateFrameworkTaxonomyTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{Repo, Scope}
  alias RhoFrameworks.UseCases.GenerateFrameworkTaxonomy

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "Taxonomy Test Org",
      slug: "taxonomy-test-#{System.unique_integer([:positive])}"
    })

    session_id = "sess-taxonomy-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:rho_frameworks, :generate_taxonomy_fn)
      DataTable.stop(session_id)
    end)

    %{org_id: org_id, session_id: session_id}
  end

  defp scope(org_id, session_id) do
    %Scope{
      organization_id: org_id,
      session_id: session_id,
      user_id: "user-test",
      source: :flow,
      reason: "wizard:create-framework"
    }
  end

  test "streams taxonomy rows and reconciles final result idempotently", %{
    org_id: org_id,
    session_id: session_id
  } do
    Application.put_env(:rho_frameworks, :generate_taxonomy_fn, fn input, on_partial ->
      on_partial.(:cluster, %{
        category: "Engineering",
        category_description: "Engineering work.",
        cluster: "Architecture",
        cluster_description: "System design.",
        target_skill_count: 3,
        transferability: "transferable",
        rationale: "Core cluster."
      })

      {:ok,
       %{
         name: input.name,
         description: input.description,
         categories: [
           %{
             name: "Engineering",
             description: "Engineering work.",
             rationale: "Core category.",
             clusters: [
               %{
                 name: "Architecture",
                 description: "System design.",
                 rationale: "Core cluster.",
                 target_skill_count: 3,
                 transferability: "transferable"
               }
             ]
           }
         ]
       }}
    end)

    assert {:ok, summary} =
             GenerateFrameworkTaxonomy.run(
               %{
                 name: "Engineering",
                 description: "Engineering framework",
                 taxonomy_size: "compact",
                 specificity: "industry_specific"
               },
               scope(org_id, session_id)
             )

    assert summary.taxonomy_table_name == "taxonomy:Engineering"
    assert summary.table_name == "taxonomy:Engineering"
    assert summary.category_count == 1
    assert summary.cluster_count == 1
    assert summary.preferences.taxonomy_size == "compact"

    assert [row] = DataTable.get_rows(session_id, table: "taxonomy:Engineering")
    assert Rho.MapAccess.get(row, :category) == "Engineering"
    assert Rho.MapAccess.get(row, :cluster) == "Architecture"

    assert [] = DataTable.get_rows(session_id, table: "library:Engineering")
  end

  test "validates required intake", %{org_id: org_id, session_id: session_id} do
    assert {:error, :missing_name} =
             GenerateFrameworkTaxonomy.run(%{description: "x"}, scope(org_id, session_id))

    assert {:error, :missing_description} =
             GenerateFrameworkTaxonomy.run(%{name: "x"}, scope(org_id, session_id))
  end
end
