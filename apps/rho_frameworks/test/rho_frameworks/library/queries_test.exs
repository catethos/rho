defmodule RhoFrameworks.Library.QueriesTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.Accounts.Organization
  alias RhoFrameworks.Frameworks.{Library, RoleProfile, RoleSkill, Skill}
  alias RhoFrameworks.Library.Queries
  alias RhoFrameworks.Repo

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%Organization{
      id: org_id,
      name: "Query Org",
      slug: "query-org-#{System.unique_integer([:positive])}"
    })

    %{org_id: org_id}
  end

  test "list_libraries/2 and library_summary/1 expose read-model rows", %{org_id: org_id} do
    lib = insert_library!(org_id, name: "Core Skills")
    _public = insert_library!(insert_org!(), name: "Public Skills", visibility: "public")
    _immutable = insert_library!(org_id, name: "Immutable Skills", immutable: true)
    insert_skill!(lib.id, name: "SQL", category: "Data")
    insert_skill!(lib.id, name: "Elixir", category: "Engineering")

    rows = Queries.list_libraries(org_id, exclude_immutable: true)

    assert Enum.any?(rows, &(&1.id == lib.id and &1.skill_count == 2))
    refute Enum.any?(rows, &(&1.name == "Immutable Skills"))
    assert Enum.any?(rows, &(&1.name == "Public Skills"))

    assert RhoFrameworks.Library.list_libraries(org_id, exclude_immutable: true) == rows

    summary = Queries.library_summary(org_id)
    core = Enum.find(summary, &(&1.id == lib.id))

    assert core.skill_count == 2
    assert %{category: "Data", skills: ["SQL"]} in core.categories
  end

  test "skill read models support rows, index, cluster, search, and browse", %{org_id: org_id} do
    lib = insert_library!(org_id, name: "Skill Reads")
    sql = insert_skill!(lib.id, name: "SQL", category: "Data", cluster: "Storage")
    _draft = insert_skill!(lib.id, name: "Draft Skill", category: "Data", status: "draft")

    assert Queries.load_library_rows(lib.id, status: "published") == [
             %{
               category: "Data",
               cluster: "Storage",
               skill_name: "SQL",
               skill_description: "",
               proficiency_levels: []
             }
           ]

    assert [%{category: "Data", cluster: "Storage", count: 1}] =
             Queries.list_skill_index(lib.id, status: "published")

    assert [%{id: id, name: "SQL"}] = Queries.list_cluster_skills(lib.id, "Data", "Storage")
    assert id == sql.id
    assert Queries.cluster_for_skill(lib.id, sql.id) == {"Data", "Storage"}
    assert [%{name: "SQL"}] = Queries.search_in_library(lib.id, "S!Q?L", status: "published")
    assert [%{name: "SQL"}] = Queries.browse_library(lib.id, status: "published")
    assert [%Skill{name: "SQL"}] = Queries.search_skills(lib.id, "S!Q?L", status: "published")
  end

  test "search_skills_across/3 scopes public visibility", %{org_id: org_id} do
    own = insert_library!(org_id, name: "Own")
    public = insert_library!(insert_org!(), name: "Public", visibility: "public")
    private = insert_library!(insert_org!(), name: "Private")

    insert_skill!(own.id, name: "SQL Own", category: "Data")
    insert_skill!(public.id, name: "SQL Public", category: "Data")
    insert_skill!(private.id, name: "SQL Private", category: "Data")

    visible = Queries.search_skills_across(org_id, "SQL")
    names = Enum.map(visible, & &1.name)

    assert "SQL Own" in names
    assert "SQL Public" in names
    refute "SQL Private" in names

    own_only = Queries.search_skills_across(org_id, "SQL", include_public: false)
    assert Enum.map(own_only, & &1.name) == ["SQL Own"]
  end

  test "list_role_profiles_for_library/2 finds profiles linked to matching skills", %{
    org_id: org_id
  } do
    lib = insert_library!(org_id, name: "Role Link")
    sql = insert_skill!(lib.id, name: "SQL", category: "Data")
    other = insert_skill!(lib.id, name: "Elixir", category: "Engineering")
    role = insert_role_profile!(org_id, "Data Engineer")
    other_role = insert_role_profile!(org_id, "Backend Engineer")
    insert_role_skill!(role.id, sql.id)
    insert_role_skill!(other_role.id, other.id)

    assert [%RoleProfile{name: "Data Engineer"}] =
             Queries.list_role_profiles_for_library(lib.id, category: "Data")
  end

  defp insert_library!(org_id, attrs) do
    attrs = Map.new(attrs)

    Repo.insert!(%Library{
      name: Map.fetch!(attrs, :name),
      organization_id: org_id,
      type: Map.get(attrs, :type, "skill"),
      immutable: Map.get(attrs, :immutable, false),
      visibility: Map.get(attrs, :visibility, "private"),
      version: Map.get(attrs, :version),
      published_at: Map.get(attrs, :published_at)
    })
  end

  defp insert_org! do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%Organization{
      id: org_id,
      name: "Other Org",
      slug: "other-org-#{System.unique_integer([:positive])}"
    })

    org_id
  end

  defp insert_skill!(library_id, attrs) do
    attrs = Map.new(attrs)
    name = Map.fetch!(attrs, :name)

    Repo.insert!(%Skill{
      library_id: library_id,
      name: name,
      slug: Skill.slugify(name),
      category: Map.get(attrs, :category),
      cluster: Map.get(attrs, :cluster),
      status: Map.get(attrs, :status, "published"),
      description: Map.get(attrs, :description, ""),
      proficiency_levels: Map.get(attrs, :proficiency_levels, [])
    })
  end

  defp insert_role_profile!(org_id, name) do
    Repo.insert!(%RoleProfile{
      organization_id: org_id,
      name: name,
      visibility: "private",
      immutable: false,
      work_activities: []
    })
  end

  defp insert_role_skill!(role_profile_id, skill_id) do
    Repo.insert!(%RoleSkill{
      role_profile_id: role_profile_id,
      skill_id: skill_id,
      min_expected_level: 1,
      weight: 1.0,
      required: true
    })
  end
end
