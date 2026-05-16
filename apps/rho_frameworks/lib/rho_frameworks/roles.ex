defmodule RhoFrameworks.Roles do
  @moduledoc "Context for role profile CRUD, skill assignments, comparison, and career ladders."
  require Logger
  import Ecto.Query
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Frameworks.{Library, RoleProfile, RoleSkill, Skill}
  alias RhoFrameworks.Library, as: Lib

  def list_role_profiles(org_id, opts \\ []) do
    role_family = Keyword.get(opts, :role_family)
    include_public = Keyword.get(opts, :include_public, true)

    from(rp in RoleProfile,
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
        organization_id: rp.organization_id,
        skill_count: count(rs.id),
        updated_at: rp.updated_at
      }
    )
    |> maybe_include_public_roles(org_id, include_public)
    |> maybe_filter_family(role_family)
    |> Repo.all()
  end

  def get_role_profile(org_id, id) do
    Repo.get_by(RoleProfile, id: id, organization_id: org_id)
  end

  def get_role_profile!(org_id, id) do
    Repo.get_by!(RoleProfile, id: id, organization_id: org_id)
  end

  @doc "Fetch a visible role profile with role_skills and nested skill preloaded."
  def get_visible_role_profile_with_skills!(org_id, id) do
    get_visible_role_profile!(org_id, id) |> Repo.preload(role_skills: :skill)
  end

  @doc "Fetch a role profile visible to the org: own role or any public role."
  def get_visible_role_profile!(org_id, id) do
    case get_role_profile(org_id, id) do
      nil -> Repo.one!(from(rp in RoleProfile, where: rp.id == ^id and rp.visibility == "public"))
      rp -> rp
    end
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

  def save_role_profile(org_id, attrs, role_rows, opts \\ []) do
    role_profile_id = Keyword.get(opts, :role_profile_id)

    resolve_library_id =
      Keyword.get_lazy(opts, :resolve_library_id, fn ->
        Lib.get_or_create_default_library(org_id).id
      end)

    library = Repo.get(RhoFrameworks.Frameworks.Library, resolve_library_id)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:skills, fn _repo, _ ->
      resolve_skills_for_role(library, resolve_library_id, role_rows)
    end)
    |> Ecto.Multi.run(:role_profile, fn repo, _ ->
      case existing_role_profile(repo, org_id, attrs[:name], role_profile_id) do
        nil ->
          rp_attrs =
            attrs
            |> Map.put(:organization_id, org_id)
            |> add_role_embedding_attrs(nil, role_rows)

          %RoleProfile{} |> RoleProfile.changeset(rp_attrs) |> repo.insert()

        existing ->
          rp_attrs =
            attrs
            |> Map.put(:organization_id, org_id)
            |> add_role_embedding_attrs(existing, role_rows)

          existing |> RoleProfile.changeset(rp_attrs) |> repo.update()
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
            min_expected_level: row[:required_level] || 1,
            required: Map.get(row, :required, true),
            weight: Map.get(row, :weight, 1.0),
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

  defp existing_role_profile(repo, org_id, _name, role_profile_id)
       when is_binary(role_profile_id) and role_profile_id != "" do
    repo.get_by(RoleProfile, id: role_profile_id, organization_id: org_id)
  end

  defp existing_role_profile(repo, org_id, name, _role_profile_id) do
    repo.get_by(RoleProfile, organization_id: org_id, name: name)
  end

  defp resolve_skills_for_role(%{immutable: true}, library_id, role_rows) do
    resolve_immutable_skills(library_id, role_rows)
  end

  defp resolve_skills_for_role(_library, library_id, role_rows) do
    resolve_mutable_skills(library_id, role_rows)
  end

  defp resolve_immutable_skills(library_id, role_rows) do
    slugs = Enum.map(role_rows, fn r -> Skill.slugify(r[:skill_name] || r[:name]) end)

    skill_by_slug =
      from(s in Skill, where: s.library_id == ^library_id and s.slug in ^slugs)
      |> Repo.all()
      |> Map.new(&{&1.slug, &1})

    role_rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      name = row[:skill_name] || row[:name]
      slug = Skill.slugify(name)

      case Map.get(skill_by_slug, slug) do
        nil -> {:halt, {:error, "Skill '#{name}' not found in immutable library"}}
        skill -> {:cont, {:ok, [{skill, row} | acc]}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _} = err -> err
    end
  end

  defp resolve_mutable_skills(library_id, role_rows) do
    skill_attrs =
      role_rows
      |> Enum.map(fn row ->
        %{
          category: row[:category] || "",
          cluster: row[:cluster] || "",
          name: row[:skill_name] || row[:name],
          description: row[:skill_description] || "",
          status: "draft"
        }
      end)
      |> Enum.uniq_by(fn a -> Skill.slugify(a[:name]) end)

    case Lib.bulk_upsert_skills(library_id, skill_attrs) do
      {:ok, skills} ->
        by_slug = Map.new(skills, &{&1.slug, &1})

        pairs =
          Enum.map(role_rows, fn row ->
            slug = Skill.slugify(row[:skill_name] || row[:name])
            {Map.fetch!(by_slug, slug), row}
          end)

        {:ok, pairs}

      {:error, _} = err ->
        err
    end
  end

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

  def compare_role_profiles(org_id, profile_names) when is_list(profile_names) do
    profiles =
      from(rp in RoleProfile,
        where: rp.organization_id == ^org_id and rp.name in ^profile_names,
        preload: [role_skills: :skill]
      )
      |> Repo.all()

    id_to_name =
      profiles
      |> Enum.flat_map(& &1.role_skills)
      |> Map.new(fn rs -> {rs.skill.id, rs.skill.name} end)

    skill_sets =
      Map.new(profiles, fn rp ->
        ids = rp.role_skills |> Enum.map(& &1.skill.id) |> MapSet.new()
        {rp.name, ids}
      end)

    all_skill_ids =
      Enum.reduce(skill_sets, MapSet.new(), fn {_k, ids}, acc -> MapSet.union(acc, ids) end)

    shared_ids =
      Enum.reduce(skill_sets, nil, fn
        {_name, ids}, nil -> ids
        {_name, ids}, acc -> MapSet.intersection(acc, ids)
      end) || MapSet.new()

    unique_per_role =
      Map.new(skill_sets, fn {name, ids} ->
        others =
          skill_sets
          |> Map.delete(name)
          |> Enum.reduce(MapSet.new(), fn {_k, ids}, acc -> MapSet.union(acc, ids) end)

        unique_names = ids |> MapSet.difference(others) |> Enum.map(&id_to_name[&1])
        {name, unique_names}
      end)

    %{
      roles: Map.keys(skill_sets),
      total_unique_skills: MapSet.size(all_skill_ids),
      shared_skills: shared_ids |> Enum.map(&id_to_name[&1]),
      shared_count: MapSet.size(shared_ids),
      unique_per_role: unique_per_role
    }
  end

  @doc """
  Build a cross-role summary of all role profiles in an organization.

  Groups the shared skill set (skills every role requires) versus the set of
  skills that are unique to each role. Useful as the agent's "what does this
  org look like?" bootstrap.

  Returns:

      %{
        role_count: non_neg_integer(),
        total_unique_skills: non_neg_integer(),
        shared_skills: [skill_name],
        shared_count: non_neg_integer(),
        unique_per_role: %{role_name => [skill_name]},
        role_families: %{family => [role_name]},
        roles: [%{name, role_family, seniority_level, skill_count}]
      }
  """
  def org_view(org_id) do
    profiles =
      from(rp in RoleProfile,
        where: rp.organization_id == ^org_id,
        order_by: [rp.role_family, rp.seniority_level, rp.name],
        preload: [role_skills: :skill]
      )
      |> Repo.all()

    case profiles do
      [] ->
        %{
          role_count: 0,
          total_unique_skills: 0,
          shared_skills: [],
          shared_count: 0,
          unique_per_role: %{},
          role_families: %{},
          roles: []
        }

      _ ->
        id_to_name =
          profiles
          |> Enum.flat_map(& &1.role_skills)
          |> Map.new(fn rs -> {rs.skill.id, rs.skill.name} end)

        skill_sets =
          Map.new(profiles, fn rp ->
            ids = rp.role_skills |> Enum.map(& &1.skill.id) |> MapSet.new()
            {rp.name, ids}
          end)

        all_skill_ids =
          Enum.reduce(skill_sets, MapSet.new(), fn {_k, ids}, acc -> MapSet.union(acc, ids) end)

        shared_ids =
          Enum.reduce(skill_sets, nil, fn
            {_name, ids}, nil -> ids
            {_name, ids}, acc -> MapSet.intersection(acc, ids)
          end) || MapSet.new()

        unique_per_role =
          Map.new(skill_sets, fn {name, ids} ->
            others =
              skill_sets
              |> Map.delete(name)
              |> Enum.reduce(MapSet.new(), fn {_k, ids}, acc -> MapSet.union(acc, ids) end)

            unique_names =
              ids |> MapSet.difference(others) |> Enum.map(&id_to_name[&1]) |> Enum.sort()

            {name, unique_names}
          end)

        role_families =
          profiles
          |> Enum.group_by(
            fn rp -> rp.role_family || "Unassigned" end,
            & &1.name
          )

        roles =
          Enum.map(profiles, fn rp ->
            %{
              name: rp.name,
              role_family: rp.role_family,
              seniority_level: rp.seniority_level,
              skill_count: length(rp.role_skills)
            }
          end)

        %{
          role_count: length(profiles),
          total_unique_skills: MapSet.size(all_skill_ids),
          shared_skills: shared_ids |> Enum.map(&id_to_name[&1]) |> Enum.sort(),
          shared_count: MapSet.size(shared_ids),
          unique_per_role: unique_per_role,
          role_families: role_families,
          roles: roles
        }
    end
  end

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

  @default_max_distance 0.6
  def find_similar_roles(org_id, query, opts \\ []) do
    find_similar_roles_semantic(org_id, query, opts)
  end

  @doc """
  LIKE-only synchronous search. Returns the same map shape as the semantic
  branch. Intended for the instant-render tier in LiveView, before the
  semantic backfill arrives.

  Pass `:library_id` to restrict candidates to role profiles that
  reference at least one skill from that library.
  """
  def find_similar_roles_fast(org_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    library_id = Keyword.get(opts, :library_id)
    find_similar_roles_fallback(org_id, query, limit, library_id)
  end

  @doc """
  Embedding-KNN search with a process-wide query→vector cache. Falls back
  to LIKE on empty query, embed failure, or no embedded rows visible to
  the org.

  Pass `:library_id` to restrict candidates to role profiles that
  reference at least one skill from that library.
  """
  def find_similar_roles_semantic(org_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    k = Keyword.get(opts, :k, 25)
    max_distance = Keyword.get(opts, :max_distance, @default_max_distance)
    library_id = Keyword.get(opts, :library_id)

    case maybe_embed_query(query) do
      {:ok, query_vec} ->
        find_similar_roles_via_knn(org_id, query_vec, k, limit, max_distance, library_id) ||
          find_similar_roles_fallback(org_id, query, limit, library_id)

      :unavailable ->
        find_similar_roles_fallback(org_id, query, limit, library_id)
    end
  end

  defp maybe_embed_query(query) when query in [nil, ""] do
    :unavailable
  end

  defp maybe_embed_query(query) when is_binary(query) do
    case RhoFrameworks.Roles.EmbeddingCache.get(query) do
      {:ok, vec} -> {:ok, vec}
      :miss -> embed_and_cache(query)
    end
  end

  defp add_role_embedding_attrs(attrs, existing, role_rows) do
    text = role_embed_text_for(attrs, existing, role_rows)
    hash = text_hash(text)

    if existing && existing.embedding_text_hash == hash && not is_nil(existing.embedding) do
      attrs
    else
      case rho_embed_one(text) do
        {:ok, vec} -> put_embedding_fields(attrs, vec, hash)
        {:error, _} -> attrs
      end
    end
  end

  defp role_embed_text_for(attrs, existing, role_rows) do
    [
      attrs[:name] || (existing && existing.name),
      attrs[:description] || (existing && existing.description),
      attrs[:purpose] || (existing && existing.purpose),
      role_skill_names_text(role_rows)
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n")
  end

  defp role_skill_names_text(role_rows) when is_list(role_rows) do
    role_rows
    |> Enum.map(&(&1[:skill_name] || &1[:name]))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp role_skill_names_text(_role_rows), do: nil

  defp put_embedding_fields(attrs, vec, hash) do
    Map.merge(attrs, %{embedding: vec, embedding_text_hash: hash, embedded_at: DateTime.utc_now()})
  end

  defp text_hash(text) do
    :crypto.hash(:sha256, text)
  end

  defp rho_embed_one(text) do
    case rho_embed_many([text]) do
      {:ok, [vec]} -> {:ok, vec}
      other -> other
    end
  end

  defp rho_embed_many(texts) do
    case RhoEmbeddings.embed_many(texts) do
      {:ok, vecs} ->
        {:ok, vecs}

      {:error, reason} = err ->
        Logger.warning(
          "RhoEmbeddings.embed_many failed (#{inspect(reason)}); saving role profile without embedding"
        )

        err
    end
  catch
    :exit, reason ->
      Logger.warning(
        "RhoEmbeddings.Server unavailable (#{inspect(reason)}); saving role profile without embedding"
      )

      {:error, :not_running}
  end

  defp embed_and_cache(query) do
    if RhoEmbeddings.ready?() do
      case RhoEmbeddings.embed_many([query]) do
        {:ok, [vec]} ->
          RhoFrameworks.Roles.EmbeddingCache.put(query, vec)
          {:ok, vec}

        other ->
          Logger.warning(
            "[find_similar_roles] embed_many failed: #{inspect(other)}, using LIKE fallback"
          )

          :unavailable
      end
    else
      :unavailable
    end
  end

  defp find_similar_roles_via_knn(org_id, query_vec, k, limit, max_distance, library_id) do
    has_embedded? =
      from(rp in RoleProfile,
        where: rp.organization_id == ^org_id or rp.visibility == "public",
        where: not is_nil(rp.embedding),
        select: 1,
        limit: 1
      )
      |> maybe_filter_library(library_id)
      |> Repo.one() == 1

    if not has_embedded? do
      nil
    else
      candidate_ids =
        from(rp in RoleProfile,
          where: rp.organization_id == ^org_id or rp.visibility == "public",
          where: not is_nil(rp.embedding),
          where:
            fragment("? <=> ?", rp.embedding, type(^query_vec, Pgvector.Ecto.Vector)) <
              ^max_distance,
          order_by: fragment("? <=> ?", rp.embedding, type(^query_vec, Pgvector.Ecto.Vector)),
          limit: ^k,
          select: rp.id
        )
        |> maybe_filter_library(library_id)
        |> Repo.all()

      knn_results(candidate_ids, limit)
    end
  end

  defp knn_results([], _limit) do
    []
  end

  defp knn_results(ids, limit) do
    id_index = Map.new(Enum.with_index(ids), fn {id, idx} -> {id, idx} end)

    from(rp in RoleProfile,
      where: rp.id in ^ids,
      left_join: rs in RoleSkill,
      on: rs.role_profile_id == rp.id,
      group_by: rp.id,
      select: %{
        id: rp.id,
        name: rp.name,
        role_family: rp.role_family,
        seniority_label: rp.seniority_label,
        skill_count: count(rs.id),
        organization_id: rp.organization_id
      }
    )
    |> Repo.all()
    |> Enum.sort_by(fn r -> Map.fetch!(id_index, r.id) end)
    |> Enum.take(limit)
    |> attach_source_libraries()
  end

  defp find_similar_roles_fallback(org_id, query, limit, library_id) do
    pattern = "%#{sanitize_query(query)}%"

    from(rp in RoleProfile,
      where: rp.organization_id == ^org_id or rp.visibility == "public",
      where:
        like(rp.name, ^pattern) or like(rp.role_family, ^pattern) or
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
        skill_count: count(rs.id),
        organization_id: rp.organization_id
      }
    )
    |> maybe_filter_library(library_id)
    |> Repo.all()
    |> attach_source_libraries()
  end

  defp maybe_filter_library(query, nil) do
    query
  end

  defp maybe_filter_library(query, library_id) when is_binary(library_id) do
    profile_ids_in_library =
      from(rs in RoleSkill,
        join: s in Skill,
        on: s.id == rs.skill_id,
        where: s.library_id == ^library_id,
        select: rs.role_profile_id,
        distinct: true
      )

    from(rp in query, where: rp.id in subquery(profile_ids_in_library))
  end

  defp attach_source_libraries([]), do: []

  defp attach_source_libraries(results) do
    role_ids = Enum.map(results, & &1.id)

    libraries_by_role =
      from(rs in RoleSkill,
        join: s in Skill,
        on: s.id == rs.skill_id,
        join: l in Library,
        on: l.id == s.library_id,
        where: rs.role_profile_id in ^role_ids,
        order_by: [l.name],
        select: %{
          role_profile_id: rs.role_profile_id,
          library_id: l.id,
          library_name: l.name
        }
      )
      |> Repo.all()
      |> Enum.uniq_by(&{&1.role_profile_id, &1.library_id})
      |> Enum.group_by(& &1.role_profile_id, fn row ->
        %{id: row.library_id, name: row.library_name}
      end)

    Enum.map(results, fn result ->
      source_libraries = Map.get(libraries_by_role, result.id, [])
      source_library_names = Enum.map_join(source_libraries, ", ", & &1.name)

      result
      |> Map.put(:source_libraries, source_libraries)
      |> Map.put(:source_library_names, source_library_names)
    end)
  end

  def clone_role_skills(org_id, role_profile_ids) when is_list(role_profile_ids) do
    profiles =
      from(rp in RoleProfile,
        where:
          (rp.organization_id == ^org_id or rp.visibility == "public") and
            rp.id in ^role_profile_ids,
        preload: [role_skills: :skill]
      )
      |> Repo.all()

    profiles
    |> Enum.flat_map(& &1.role_skills)
    |> Enum.reduce(%{}, fn rs, acc ->
      key = rs.skill.id

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
    |> Enum.sort_by(fn {_k, x} -> {x.category, x.cluster, x.skill_name} end)
    |> Enum.map(fn {_, v} -> v end)
  end

  @doc """
  Total count of role-skill rows across the given role profiles, before
  any cross-role union. Pair with `clone_skills_for_library/2` row count
  to compute how many duplicates were collapsed at union time
  (`merged = total_role_skills - unique_skills_in_library`).
  """
  @spec count_role_skills_for_profiles(String.t(), [String.t()]) :: non_neg_integer()
  def count_role_skills_for_profiles(org_id, role_profile_ids)
      when is_binary(org_id) and is_list(role_profile_ids) do
    case role_profile_ids do
      [] ->
        0

      ids ->
        from(rs in RoleSkill,
          join: rp in RoleProfile,
          on: rs.role_profile_id == rp.id,
          where: (rp.organization_id == ^org_id or rp.visibility == "public") and rp.id in ^ids,
          select: count(rs.id)
        )
        |> Repo.one()
    end
  end

  @doc """
  Returns the skills that are referenced by ≥2 of the given role
  profiles — i.e. the exact-id duplicates that `clone_skills_for_library/2`
  collapses at union time. Each entry includes the role names that
  contained that skill so callers can show the user *which* skills
  overlapped, not just how many.

  Sorted by skill_name. Returns `[]` for an empty input list.
  """
  @spec list_cross_role_duplicates(String.t(), [String.t()]) :: [
          %{skill_id: String.t(), skill_name: String.t(), role_names: [String.t()]}
        ]
  def list_cross_role_duplicates(org_id, role_profile_ids)
      when is_binary(org_id) and is_list(role_profile_ids) do
    case role_profile_ids do
      [] ->
        []

      ids ->
        from(rs in RoleSkill,
          join: rp in RoleProfile,
          on: rs.role_profile_id == rp.id,
          join: s in Skill,
          on: rs.skill_id == s.id,
          where: (rp.organization_id == ^org_id or rp.visibility == "public") and rp.id in ^ids,
          group_by: [s.id, s.name],
          having: count(fragment("DISTINCT ?", rp.id)) > 1,
          select: %{
            skill_id: s.id,
            skill_name: s.name,
            role_names: fragment("array_agg(DISTINCT ?)", rp.name)
          },
          order_by: s.name
        )
        |> Repo.all()
    end
  end

  @doc """
  Library-shaped clone: union the given roles' skills and emit rows
  matching `RhoFrameworks.DataTableSchemas.library_schema/0`. Includes
  `skill_description` and the full `proficiency_levels` array attached
  to each skill so downstream library tables get the proficiency data,
  not just the names.

  Skills appearing in multiple roles are kept once (first occurrence —
  proficiency_levels live on `Skill`, so duplicates would carry
  identical values).
  """
  @spec clone_skills_for_library(String.t(), [String.t()]) :: [map()]
  def clone_skills_for_library(org_id, role_profile_ids) when is_list(role_profile_ids) do
    profiles =
      from(rp in RoleProfile,
        where:
          (rp.organization_id == ^org_id or rp.visibility == "public") and
            rp.id in ^role_profile_ids,
        preload: [role_skills: :skill]
      )
      |> Repo.all()

    profiles
    |> Enum.flat_map(& &1.role_skills)
    |> Enum.reduce(%{}, fn rs, acc ->
      Map.put_new(acc, rs.skill.id, %{
        category: rs.skill.category || "",
        cluster: rs.skill.cluster || "",
        skill_name: rs.skill.name,
        skill_description: rs.skill.description || "",
        proficiency_levels: normalize_levels(rs.skill.proficiency_levels)
      })
    end)
    |> Enum.sort_by(fn {_k, x} -> {x.category, x.cluster, x.skill_name} end)
    |> Enum.map(fn {_, v} -> v end)
  end

  defp normalize_levels(nil) do
    []
  end

  defp normalize_levels([]) do
    []
  end

  defp normalize_levels(levels) when is_list(levels) do
    Enum.map(levels, fn lvl ->
      %{
        level: get_level_field(lvl, :level) || get_level_field(lvl, :level_number) || 0,
        level_name: get_level_field(lvl, :level_name) || "",
        level_description: get_level_field(lvl, :level_description) || ""
      }
    end)
  end

  defp get_level_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_level_field(_, _) do
    nil
  end

  defp add_progressive_diffs(profiles) do
    profiles
    |> Enum.reduce({MapSet.new(), []}, fn profile, {prev_skills, acc} ->
      new_skills = MapSet.difference(profile.skill_set, prev_skills)
      dropped_skills = MapSet.difference(prev_skills, profile.skill_set)
      entry = Map.merge(profile, %{new_skills: new_skills, dropped_skills: dropped_skills})
      {profile.skill_set, [entry | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp maybe_include_public_roles(query, org_id, true) do
    from(rp in query, where: rp.organization_id == ^org_id or rp.visibility == "public")
  end

  defp maybe_include_public_roles(query, org_id, false) do
    from(rp in query, where: rp.organization_id == ^org_id)
  end

  defp maybe_filter_family(query, nil) do
    query
  end

  defp maybe_filter_family(query, family) do
    from(rp in query, where: rp.role_family == ^family)
  end

  defp sanitize_query(query) do
    query |> String.replace(~r/[^\w\s]/, "") |> String.trim()
  end
end
