defmodule RhoFrameworks.UseCases.GenerateSkillsForTaxonomyTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{DataTableSchemas, Repo, Scope}
  alias RhoFrameworks.UseCases.GenerateSkillsForTaxonomy

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "Taxonomy Skills Test Org",
      slug: "taxonomy-skills-test-#{System.unique_integer([:positive])}"
    })

    session_id = "sess-taxonomy-skills-#{System.unique_integer([:positive])}"
    {:ok, _} = DataTable.ensure_started(session_id)

    :ok =
      DataTable.ensure_table(
        session_id,
        "taxonomy:Engineering",
        DataTableSchemas.taxonomy_schema()
      )

    {:ok, _} =
      DataTable.add_rows(
        session_id,
        [
          %{
            category: "Engineering",
            category_description: "Engineering work.",
            cluster: "Architecture",
            cluster_description: "System design.",
            target_skill_count: 2,
            transferability: "transferable",
            rationale: "Core cluster."
          }
        ],
        table: "taxonomy:Engineering"
      )

    on_exit(fn ->
      Application.delete_env(:rho_frameworks, :generate_skills_for_taxonomy_fn)
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

  test "writes only skills that belong to the approved taxonomy", %{
    org_id: org_id,
    session_id: session_id
  } do
    parent = self()

    Application.put_env(:rho_frameworks, :generate_skills_for_taxonomy_fn, fn input, on_partial ->
      send(parent, {:seam_input, input})

      on_partial.(:skill, %{
        category: "Engineering",
        cluster: "Architecture",
        name: "System Design",
        description: "Designs system boundaries."
      })

      {:ok,
       %{
         skills: [
           %{
             category: "Engineering",
             cluster: "Architecture",
             name: "System Design",
             description: "Designs system boundaries."
           },
           %{
             category: "Engineering",
             cluster: "Delivery",
             name: "Release Planning",
             description: "Plans releases."
           }
         ]
       }}
    end)

    assert {:ok, summary} =
             GenerateSkillsForTaxonomy.run(
               %{name: "Engineering", description: "Engineering framework"},
               scope(org_id, session_id)
             )

    assert summary.table_name == "library:Engineering"
    assert summary.taxonomy_table_name == "taxonomy:Engineering"
    assert summary.returned == 2
    assert summary.rejected_count == 1
    assert [%{name: "Release Planning", cluster: "Delivery"}] = summary.rejected

    assert [row] = DataTable.get_rows(session_id, table: "library:Engineering")
    assert Rho.MapAccess.get(row, :skill_name) == "System Design"
    assert Rho.MapAccess.get(row, :cluster) == "Architecture"

    assert_received {:seam_input, seam_input}
    assert seam_input.taxonomy =~ "Engineering / Architecture"
  end

  test "returns empty_taxonomy when no taxonomy rows exist", %{
    org_id: org_id,
    session_id: session_id
  } do
    assert {:error, :empty_taxonomy} =
             GenerateSkillsForTaxonomy.run(
               %{
                 name: "Empty",
                 description: "No taxonomy",
                 taxonomy_table_name: "taxonomy:Missing"
               },
               scope(org_id, session_id)
             )
  end
end
