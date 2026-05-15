defmodule RhoFrameworks.Library.Queries do
  @moduledoc """
  Read-only library queries and table-shaped read models.

  `RhoFrameworks.Library` remains the public facade. This module owns query
  composition and projection shapes so write workflows, versioning, and dedup
  logic can evolve without also carrying the read-model surface.
  """

  import Ecto.Query

  alias RhoFrameworks.Frameworks.{
    Library,
    RoleProfile,
    RoleSkill,
    Skill
  }

  alias RhoFrameworks.Repo

  def list_libraries(org_id, opts \\ []) do
    type = Keyword.get(opts, :type)
    exclude_immutable = Keyword.get(opts, :exclude_immutable, false)
    only = Keyword.get(opts, :only)
    include_public = Keyword.get(opts, :include_public, true)

    from(l in Library,
      left_join: s in Skill,
      on: s.library_id == l.id,
      group_by: l.id,
      order_by: [desc: l.updated_at],
      select: %{
        id: l.id,
        name: l.name,
        description: l.description,
        type: l.type,
        immutable: l.immutable,
        derived_from_id: l.derived_from_id,
        source_key: l.source_key,
        version: l.version,
        published_at: l.published_at,
        is_default: l.is_default,
        visibility: l.visibility,
        skill_count: count(s.id),
        updated_at: l.updated_at
      }
    )
    |> maybe_include_public(org_id, include_public)
    |> maybe_filter_type(type)
    |> maybe_exclude_immutable(exclude_immutable)
    |> maybe_filter_version_scope(only)
    |> Repo.all()
  end

  def library_summary(org_id) do
    libraries =
      from(l in Library,
        where: l.organization_id == ^org_id,
        order_by: [desc: l.updated_at],
        select: %{
          id: l.id,
          name: l.name,
          immutable: l.immutable,
          version: l.version,
          published_at: l.published_at
        }
      )
      |> Repo.all()

    if libraries == [] do
      []
    else
      library_ids = Enum.map(libraries, & &1.id)

      skills_by_library =
        from(s in Skill,
          where: s.library_id in ^library_ids,
          order_by: [s.category, s.cluster, s.name],
          select: %{library_id: s.library_id, category: s.category, name: s.name}
        )
        |> Repo.all()
        |> Enum.group_by(& &1.library_id)

      build_library_summary(libraries, skills_by_library)
    end
  end

  def get_library_by_name(org_id, name) do
    from(l in Library,
      where: l.organization_id == ^org_id and l.name == ^name,
      order_by: [desc: l.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  def get_library(_org_id, nil), do: nil

  def get_library(org_id, id) when is_binary(id) do
    Repo.get_by(Library, id: id, organization_id: org_id)
  end

  def get_library!(org_id, id) do
    Repo.get_by!(Library, id: id, organization_id: org_id)
  end

  def get_visible_library!(org_id, id) do
    get_library(org_id, id) || get_public_library!(id)
  end

  def get_public_library!(id) do
    Repo.get_by!(Library, id: id, visibility: "public")
  end

  def list_versions(org_id, library_name) do
    from(l in Library,
      where: l.organization_id == ^org_id and l.name == ^library_name and not is_nil(l.version),
      left_join: s in Skill,
      on: s.library_id == l.id,
      group_by: l.id,
      order_by: [desc: l.published_at],
      select: %{
        id: l.id,
        version: l.version,
        published_at: l.published_at,
        skill_count: count(s.id),
        superseded_by_id: l.superseded_by_id,
        is_default: l.is_default
      }
    )
    |> Repo.all()
  end

  def get_latest_version(org_id, library_name) do
    from(l in Library,
      where: l.organization_id == ^org_id and l.name == ^library_name and not is_nil(l.version),
      order_by: [desc: l.published_at],
      limit: 1
    )
    |> Repo.one()
  end

  def get_default_version(org_id, library_name) do
    from(l in Library,
      where:
        l.organization_id == ^org_id and l.name == ^library_name and l.is_default == true and
          not is_nil(l.version),
      limit: 1
    )
    |> Repo.one()
  end

  def get_draft(org_id, library_name) do
    from(l in Library,
      where: l.organization_id == ^org_id and l.name == ^library_name and is_nil(l.version),
      limit: 1
    )
    |> Repo.one()
  end

  def resolve_library(org_id, library_name, nil) do
    from(l in Library,
      where: l.organization_id == ^org_id and l.name == ^library_name,
      order_by: [desc: is_nil(l.version), desc: l.is_default, desc: l.published_at],
      limit: 1
    )
    |> Repo.one()
  end

  def resolve_library(org_id, library_name, version) do
    Repo.get_by(Library, organization_id: org_id, name: library_name, version: version)
  end

  def list_skills(nil, _opts), do: []

  def list_skills(library_id, opts) when is_binary(library_id) do
    category = Keyword.get(opts, :category)
    categories = Keyword.get(opts, :categories)
    status = Keyword.get(opts, :status)

    from(s in Skill,
      where: s.library_id == ^library_id,
      order_by: [s.category, s.cluster, s.sort_order, s.name]
    )
    |> maybe_filter(:category, category)
    |> maybe_filter(:categories, categories)
    |> maybe_filter(:status, status)
    |> Repo.all()
  end

  def get_skill(library_id, id) do
    Repo.get_by(Skill, id: id, library_id: library_id)
  end

  def get_skill!(library_id, id) do
    Repo.get_by!(Skill, id: id, library_id: library_id)
  end

  def load_library_rows(library_id, opts \\ []) do
    category = Keyword.get(opts, :category)
    categories = Keyword.get(opts, :categories)
    status = Keyword.get(opts, :status)

    from(s in Skill,
      where: s.library_id == ^library_id,
      order_by: [s.category, s.cluster, s.sort_order, s.name],
      select: %{
        category: coalesce(s.category, ""),
        cluster: coalesce(s.cluster, ""),
        skill_name: s.name,
        skill_description: coalesce(s.description, ""),
        proficiency_levels: s.proficiency_levels
      }
    )
    |> maybe_filter(:category, category)
    |> maybe_filter(:categories, categories)
    |> maybe_filter(:status, status)
    |> Repo.all()
    |> Enum.map(fn row -> %{row | proficiency_levels: row.proficiency_levels || []} end)
  end

  def skill_count(library_id) when is_binary(library_id) do
    from(s in Skill, where: s.library_id == ^library_id, select: count(s.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  def list_skill_index(library_id, opts \\ []) when is_binary(library_id) do
    status = Keyword.get(opts, :status)

    from(s in Skill,
      where: s.library_id == ^library_id,
      group_by: [s.category, s.cluster],
      order_by: [s.category, s.cluster],
      select: %{category: s.category, cluster: s.cluster, count: count(s.id)}
    )
    |> maybe_filter(:status, status)
    |> Repo.all()
  end

  def list_cluster_skills(library_id, category, cluster, opts \\ []) when is_binary(library_id) do
    status = Keyword.get(opts, :status)

    from(s in Skill,
      where: s.library_id == ^library_id,
      order_by: [s.sort_order, s.name],
      select: %{
        id: s.id,
        name: s.name,
        slug: s.slug,
        category: s.category,
        cluster: s.cluster,
        status: s.status,
        description: s.description,
        proficiency_levels: s.proficiency_levels
      }
    )
    |> where_match(:category, category)
    |> where_match(:cluster, cluster)
    |> maybe_filter(:status, status)
    |> Repo.all()
  end

  def search_in_library(library_id, query, opts \\ []) when is_binary(library_id) do
    status = Keyword.get(opts, :status)
    pattern = "%#{sanitize_query(query)}%"

    from(s in Skill,
      where: s.library_id == ^library_id,
      where:
        like(s.name, ^pattern) or like(s.description, ^pattern) or like(s.category, ^pattern) or
          like(s.cluster, ^pattern),
      order_by: [s.category, s.cluster, s.sort_order, s.name],
      select: %{
        id: s.id,
        name: s.name,
        slug: s.slug,
        category: s.category,
        cluster: s.cluster,
        status: s.status,
        description: s.description,
        proficiency_levels: s.proficiency_levels
      }
    )
    |> maybe_filter(:status, status)
    |> Repo.all()
  end

  def cluster_for_skill(library_id, skill_id)
      when is_binary(library_id) and is_binary(skill_id) do
    from(s in Skill,
      where: s.library_id == ^library_id and s.id == ^skill_id,
      select: {s.category, s.cluster}
    )
    |> Repo.one()
  end

  def browse_library(library_id, opts \\ []) do
    list_skills(library_id, opts)
    |> Enum.map(fn s ->
      %{
        id: s.id,
        name: s.name,
        slug: s.slug,
        category: s.category,
        cluster: s.cluster,
        status: s.status,
        description: s.description,
        proficiency_levels: s.proficiency_levels
      }
    end)
  end

  def search_skills(library_id, query, opts \\ []) do
    category = Keyword.get(opts, :category)
    limit = Keyword.get(opts, :limit, 50)
    pattern = "%#{sanitize_query(query)}%"

    from(s in Skill,
      where: s.library_id == ^library_id,
      where:
        like(s.name, ^pattern) or like(s.description, ^pattern) or like(s.category, ^pattern) or
          like(s.cluster, ^pattern),
      limit: ^limit,
      order_by: s.name
    )
    |> maybe_filter(:category, category)
    |> Repo.all()
  end

  def search_skills_across(org_id, query, opts \\ []) do
    category = Keyword.get(opts, :category)
    limit = Keyword.get(opts, :limit, 50)
    include_public = Keyword.get(opts, :include_public, true)
    pattern = "%#{sanitize_query(query)}%"

    base =
      from(s in Skill,
        join: l in Library,
        on: s.library_id == l.id,
        where:
          like(s.name, ^pattern) or like(s.description, ^pattern) or like(s.category, ^pattern),
        limit: ^limit,
        order_by: s.name,
        select: %{
          id: s.id,
          name: s.name,
          category: s.category,
          cluster: s.cluster,
          status: s.status,
          library_id: l.id,
          library_name: l.name
        }
      )

    base
    |> scope_skills_to_visible_libraries(org_id, include_public)
    |> maybe_filter(:category, category)
    |> Repo.all()
  end

  def list_role_profiles_for_library(library_id, opts \\ []) do
    category = Keyword.get(opts, :category)
    categories = Keyword.get(opts, :categories)

    skill_query =
      from(s in Skill, where: s.library_id == ^library_id)
      |> maybe_filter(:category, category)
      |> maybe_filter(:categories, categories)

    skill_ids = Repo.all(from(s in skill_query, select: s.id))

    from(rp in RoleProfile,
      join: rs in RoleSkill,
      on: rs.role_profile_id == rp.id,
      where: rs.skill_id in ^skill_ids,
      distinct: true,
      preload: [role_skills: :skill]
    )
    |> Repo.all()
  end

  defp build_library_summary(library_rows, skills_by_library) do
    Enum.map(library_rows, fn lib ->
      skills = Map.get(skills_by_library, lib.id, [])
      by_category = Enum.group_by(skills, & &1.category)

      %{
        id: lib.id,
        name: lib.name,
        skill_count: length(skills),
        immutable: lib.immutable,
        version: lib.version,
        published_at: lib.published_at,
        categories:
          Enum.map(by_category, fn {cat, cat_skills} ->
            %{category: cat, skills: Enum.map(cat_skills, & &1.name)}
          end)
      }
    end)
  end

  defp maybe_include_public(query, org_id, true) do
    from(l in query, where: l.organization_id == ^org_id or l.visibility == "public")
  end

  defp maybe_include_public(query, org_id, false) do
    from(l in query, where: l.organization_id == ^org_id)
  end

  defp maybe_filter_type(query, nil), do: query

  defp maybe_filter_type(query, type) do
    from(l in query, where: l.type == ^type)
  end

  defp maybe_exclude_immutable(query, false), do: query

  defp maybe_exclude_immutable(query, true) do
    from(l in query, where: l.immutable == false)
  end

  defp maybe_filter_version_scope(query, nil), do: query

  defp maybe_filter_version_scope(query, :drafts) do
    from(l in query, where: is_nil(l.version))
  end

  defp maybe_filter_version_scope(query, :published) do
    from(l in query, where: not is_nil(l.version))
  end

  defp maybe_filter_version_scope(query, :latest) do
    from(l in query, where: is_nil(l.version) or is_nil(l.superseded_by_id))
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, :category, value) do
    from(s in query, where: s.category == ^value)
  end

  defp maybe_filter(query, :categories, values) when is_list(values) do
    from(s in query, where: s.category in ^values)
  end

  defp maybe_filter(query, :status, value) do
    from(s in query, where: s.status == ^value)
  end

  defp where_match(query, field, nil) do
    from(s in query, where: is_nil(field(s, ^field)))
  end

  defp where_match(query, field, value) do
    from(s in query, where: field(s, ^field) == ^value)
  end

  defp scope_skills_to_visible_libraries(query, org_id, true) do
    from([_s, l] in query, where: l.organization_id == ^org_id or l.visibility == "public")
  end

  defp scope_skills_to_visible_libraries(query, org_id, false) do
    from([_s, l] in query, where: l.organization_id == ^org_id)
  end

  defp sanitize_query(query) do
    query |> String.replace(~r/[^\w\s]/, "") |> String.trim()
  end
end
