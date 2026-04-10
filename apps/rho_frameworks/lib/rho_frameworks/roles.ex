defmodule RhoFrameworks.Roles do
  @moduledoc "Context for role profile CRUD, skill assignments, comparison, and career ladders."

  import Ecto.Query
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Frameworks.{RoleProfile, RoleSkill}
  alias RhoFrameworks.Library, as: Lib

  # --- Role Profile CRUD ---

  def list_role_profiles(org_id, opts \\ []) do
    role_family = Keyword.get(opts, :role_family)

    from(rp in RoleProfile,
      where: rp.organization_id == ^org_id,
      left_join: rs in RoleSkill,
      on: rs.role_profile_id == rp.id,
      group_by: rp.id,
      order_by: [rp.role_family, rp.seniority_level, rp.name],
      select: %{
        id: rp.id,
        name: rp.name,
        role_family: rp.role_family,
        seniority_level: rp.seniority_level,
        seniority_label: rp.seniority_label,
        purpose: rp.purpose,
        immutable: rp.immutable,
        skill_count: count(rs.id),
        updated_at: rp.updated_at
      }
    )
    |> maybe_filter_family(role_family)
    |> Repo.all()
  end

  def get_role_profile(org_id, id) do
    Repo.get_by(RoleProfile, id: id, organization_id: org_id)
  end

  def get_role_profile!(org_id, id) do
    Repo.get_by!(RoleProfile, id: id, organization_id: org_id)
  end

  def get_role_profile_by_name(org_id, name) do
    Repo.get_by(RoleProfile, organization_id: org_id, name: name)
  end

  def delete_role_profile(org_id, name) when is_binary(name) do
    case get_role_profile_by_name(org_id, name) do
      nil -> {:error, :not_found}
      rp -> Repo.delete(rp)
    end
  end

  # --- Save Role Profile ---

  def save_role_profile(org_id, attrs, role_rows, opts \\ []) do
    library_id =
      Keyword.get_lazy(opts, :library_id, fn ->
        Lib.get_or_create_default_library(org_id).id
      end)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:skills, fn _repo, _ ->
      pairs =
        Enum.map(role_rows, fn row ->
          {:ok, skill} =
            Lib.upsert_skill(library_id, %{
              category: row[:category] || row["category"] || "",
              cluster: row[:cluster] || row["cluster"] || "",
              name: row[:skill_name] || row["skill_name"] || row[:name] || row["name"],
              description:
                Map.get(row, :skill_description, Map.get(row, "skill_description", "")),
              status: "draft"
            })

          {skill, row}
        end)

      {:ok, pairs}
    end)
    |> Ecto.Multi.run(:role_profile, fn repo, _ ->
      rp_attrs = Map.put(attrs, :organization_id, org_id)

      case repo.get_by(RoleProfile, organization_id: org_id, name: attrs[:name] || attrs["name"]) do
        nil ->
          %RoleProfile{}
          |> RoleProfile.changeset(rp_attrs)
          |> repo.insert()

        existing ->
          existing
          |> RoleProfile.changeset(rp_attrs)
          |> repo.update()
      end
    end)
    |> Ecto.Multi.run(:clear_old_skills, fn repo, %{role_profile: profile} ->
      from(rs in RoleSkill, where: rs.role_profile_id == ^profile.id) |> repo.delete_all()
      {:ok, :cleared}
    end)
    |> Ecto.Multi.run(:role_skills, fn repo, %{skills: pairs, role_profile: profile} ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries =
        pairs
        |> Enum.map(fn {skill, row} ->
          %{
            id: Ecto.UUID.generate(),
            role_profile_id: profile.id,
            skill_id: skill.id,
            min_expected_level: row[:required_level] || row["required_level"] || 1,
            required: Map.get(row, :required, Map.get(row, "required", true)),
            weight: Map.get(row, :weight, Map.get(row, "weight", 1.0)),
            inserted_at: now,
            updated_at: now
          }
        end)
        |> Enum.uniq_by(& &1.skill_id)

      {count, _} = repo.insert_all(RoleSkill, entries)
      {:ok, count}
    end)
    |> Repo.transaction()
  end

  # --- Load Role Profile ---

  def load_role_profile(org_id, name) when is_binary(name) do
    case get_role_profile_by_name(org_id, name) do
      nil ->
        {:error, :not_found}

      rp ->
        rp = Repo.preload(rp, role_skills: :skill)

        rows =
          Enum.map(rp.role_skills, fn rs ->
            %{
              category: rs.skill.category,
              cluster: rs.skill.cluster,
              skill_name: rs.skill.name,
              required_level: rs.min_expected_level,
              required: rs.required
            }
          end)

        {:ok, %{role_profile: rp, rows: rows}}
    end
  end

  # --- Compare ---

  def compare_role_profiles(org_id, profile_names) when is_list(profile_names) do
    profiles =
      from(rp in RoleProfile,
        where: rp.organization_id == ^org_id and rp.name in ^profile_names,
        preload: [role_skills: :skill]
      )
      |> Repo.all()

    skill_sets =
      Map.new(profiles, fn rp ->
        skills =
          rp.role_skills
          |> Enum.map(& &1.skill.name)
          |> MapSet.new()

        {rp.name, skills}
      end)

    all_skills =
      skill_sets
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    shared =
      skill_sets
      |> Map.values()
      |> Enum.reduce(fn set, acc -> MapSet.intersection(acc, set) end)

    unique_per_role =
      Map.new(skill_sets, fn {name, skills} ->
        others =
          skill_sets
          |> Map.delete(name)
          |> Map.values()
          |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        {name, MapSet.difference(skills, others) |> MapSet.to_list()}
      end)

    %{
      roles: Map.keys(skill_sets),
      total_unique_skills: MapSet.size(all_skills),
      shared_skills: MapSet.to_list(shared),
      shared_count: MapSet.size(shared),
      unique_per_role: unique_per_role
    }
  end

  # --- Career Ladder ---

  def career_ladder(org_id, role_family) do
    from(rp in RoleProfile,
      where: rp.organization_id == ^org_id and rp.role_family == ^role_family,
      order_by: rp.seniority_level,
      preload: [role_skills: :skill]
    )
    |> Repo.all()
    |> Enum.map(fn profile ->
      skill_names = Enum.map(profile.role_skills, & &1.skill.name) |> MapSet.new()
      Map.put(profile, :skill_set, skill_names)
    end)
    |> add_progressive_diffs()
  end

  # --- Similar Roles ---

  def find_similar_roles(org_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    pattern = "%#{sanitize_query(query)}%"

    from(rp in RoleProfile,
      where: rp.organization_id == ^org_id,
      where:
        like(rp.name, ^pattern) or
          like(rp.role_family, ^pattern) or
          like(rp.description, ^pattern),
      left_join: rs in RoleSkill,
      on: rs.role_profile_id == rp.id,
      group_by: rp.id,
      limit: ^limit,
      select: %{
        id: rp.id,
        name: rp.name,
        role_family: rp.role_family,
        seniority_label: rp.seniority_label,
        skill_count: count(rs.id)
      }
    )
    |> Repo.all()
  end

  # --- Clone ---

  def clone_role_skills(org_id, role_profile_ids) when is_list(role_profile_ids) do
    profiles =
      from(rp in RoleProfile,
        where: rp.organization_id == ^org_id and rp.id in ^role_profile_ids,
        preload: [role_skills: :skill]
      )
      |> Repo.all()

    # Union skills, keep highest required_level on overlap
    profiles
    |> Enum.flat_map(& &1.role_skills)
    |> Enum.reduce(%{}, fn rs, acc ->
      key = rs.skill.name

      case Map.get(acc, key) do
        nil ->
          Map.put(acc, key, %{
            category: rs.skill.category,
            cluster: rs.skill.cluster,
            skill_name: rs.skill.name,
            required_level: rs.min_expected_level,
            required: rs.required,
            weight: rs.weight
          })

        existing ->
          merged = %{
            existing
            | required_level: max(existing.required_level, rs.min_expected_level),
              required: existing.required || rs.required
          }

          Map.put(acc, key, merged)
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1.category, &1.cluster, &1.skill_name})
  end

  # --- Private ---

  defp add_progressive_diffs(profiles) do
    profiles
    |> Enum.reduce({MapSet.new(), []}, fn profile, {prev_skills, acc} ->
      new_skills = MapSet.difference(profile.skill_set, prev_skills)
      dropped_skills = MapSet.difference(prev_skills, profile.skill_set)

      entry =
        Map.merge(profile, %{new_skills: new_skills, dropped_skills: dropped_skills})

      {profile.skill_set, [entry | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp maybe_filter_family(query, nil), do: query

  defp maybe_filter_family(query, family) do
    from(rp in query, where: rp.role_family == ^family)
  end

  defp sanitize_query(query) do
    query
    |> String.replace(~r/[^\w\s]/, "")
    |> String.trim()
  end
end
