defmodule RhoFrameworks.Roles do
  @moduledoc "Context for role profile CRUD, skill assignments, comparison, and career ladders."

  require Logger
  import Ecto.Query
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Frameworks.{RoleProfile, RoleSkill, Skill}
  alias RhoFrameworks.Library, as: Lib

  # --- Role Profile CRUD ---

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
    get_visible_role_profile!(org_id, id)
    |> Repo.preload(role_skills: :skill)
  end

  @doc "Fetch a role profile visible to the org: own role or any public role."
  def get_visible_role_profile!(org_id, id) do
    case get_role_profile(org_id, id) do
      nil ->
        Repo.one!(
          from(rp in RoleProfile,
            where: rp.id == ^id and rp.visibility == "public"
          )
        )

      rp ->
        rp
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

  # --- Save Role Profile ---

  def save_role_profile(org_id, attrs, role_rows, opts \\ []) do
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
      rp_attrs =
        attrs
        |> Map.put(:organization_id, org_id)

      case repo.get_by(RoleProfile, organization_id: org_id, name: attrs[:name]) do
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

  # Returns `{:ok, [{%Skill{}, row}, ...]}` preserving `role_rows` order.
  # Mutable libraries: a single bulk upsert against the skills table.
  # Immutable libraries: a single batched lookup; surfaces the first row
  # whose skill isn't present in the library.
  defp resolve_skills_for_role(%{immutable: true}, library_id, role_rows),
    do: resolve_immutable_skills(library_id, role_rows)

  defp resolve_skills_for_role(_library, library_id, role_rows),
    do: resolve_mutable_skills(library_id, role_rows)

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
      skill_sets
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    shared_ids =
      skill_sets
      |> Map.values()
      |> Enum.reduce(fn set, acc -> MapSet.intersection(acc, set) end)

    unique_per_role =
      Map.new(skill_sets, fn {name, ids} ->
        others =
          skill_sets
          |> Map.delete(name)
          |> Map.values()
          |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        unique_names =
          ids
          |> MapSet.difference(others)
          |> Enum.map(&id_to_name[&1])

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

  # --- Org View ---

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
          skill_sets
          |> Map.values()
          |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        shared_ids =
          skill_sets
          |> Map.values()
          |> Enum.reduce(fn set, acc -> MapSet.intersection(acc, set) end)

        unique_per_role =
          Map.new(skill_sets, fn {name, ids} ->
            others =
              skill_sets
              |> Map.delete(name)
              |> Map.values()
              |> Enum.reduce(MapSet.new(), &MapSet.union/2)

            unique_names =
              ids
              |> MapSet.difference(others)
              |> Enum.map(&id_to_name[&1])
              |> Enum.sort()

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
  #
  # Two-tier strategy. ESCO ships ~3,008 occupations, so the prior approach
  # ("load every visible role, ask the LLM which match") would overflow
  # prompt budgets and hit the LLM API on every wizard call.
  #
  #   1. Embedding KNN — when the query embeds and rows have embeddings,
  #      pgvector's HNSW index resolves the top-K nearest in sub-ms.
  #      Cosine distance is the relevance score; no LLM rerank.
  #      Results above `:max_distance` (default 0.6 ≈ 0.4 cosine sim, tuned
  #      for paraphrase-multilingual-MiniLM-L12-v2) are dropped so off-topic
  #      queries like "superman" return empty instead of nearest-anything.
  #   2. LIKE fallback — when embeddings are unavailable (server not ready,
  #      no rows embedded yet) or the query is empty, fall back to the
  #      previous SQL `like` search across name/role_family/description.

  # Cosine distance cutoff for KNN results. Calibrated for
  # paraphrase-multilingual-MiniLM-L12-v2; raise for stricter models, lower
  # for looser ones. Override per-call with `max_distance: 0.x`.
  @default_max_distance 0.6

  def find_similar_roles(org_id, query, opts \\ []),
    do: find_similar_roles_semantic(org_id, query, opts)

  @doc """
  LIKE-only synchronous search. Returns the same map shape as the semantic
  branch. Intended for the instant-render tier in LiveView, before the
  semantic backfill arrives.
  """
  def find_similar_roles_fast(org_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    find_similar_roles_fallback(org_id, query, limit)
  end

  @doc """
  Embedding-KNN search with a process-wide query→vector cache. Falls back
  to LIKE on empty query, embed failure, or no embedded rows visible to
  the org.
  """
  def find_similar_roles_semantic(org_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    k = Keyword.get(opts, :k, 25)
    max_distance = Keyword.get(opts, :max_distance, @default_max_distance)

    case maybe_embed_query(query) do
      {:ok, query_vec} ->
        find_similar_roles_via_knn(org_id, query_vec, k, limit, max_distance) ||
          find_similar_roles_fallback(org_id, query, limit)

      :unavailable ->
        find_similar_roles_fallback(org_id, query, limit)
    end
  end

  defp maybe_embed_query(query) when query in [nil, ""], do: :unavailable

  defp maybe_embed_query(query) when is_binary(query) do
    case RhoFrameworks.Roles.EmbeddingCache.get(query) do
      {:ok, vec} ->
        {:ok, vec}

      :miss ->
        embed_and_cache(query)
    end
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

  # Returns the top-K nearest roles by cosine distance with `distance <
  # max_distance`, then truncates to `limit`. Returns `nil` *only* when no
  # embedded rows are visible to the org (bootstrap case) — caller falls
  # back to LIKE. Returns `[]` when embeddings exist but no row clears the
  # distance threshold (off-topic query like "superman") — caller does NOT
  # fall back, so the UI shows "no matches" instead of nearest-anything.
  defp find_similar_roles_via_knn(org_id, query_vec, k, limit, max_distance) do
    has_embedded? =
      from(rp in RoleProfile,
        where: rp.organization_id == ^org_id or rp.visibility == "public",
        where: not is_nil(rp.embedding),
        select: 1,
        limit: 1
      )
      |> Repo.one()
      |> Kernel.==(1)

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
        |> Repo.all()

      knn_results(candidate_ids, limit)
    end
  end

  defp knn_results([], _limit), do: []

  defp knn_results(ids, limit) do
    # Re-query in the same map shape as the LIKE branch (skill_count via
    # left-join + group_by). Preserve KNN order via id_index.
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
  end

  defp find_similar_roles_fallback(org_id, query, limit) do
    pattern = "%#{sanitize_query(query)}%"

    from(rp in RoleProfile,
      where: rp.organization_id == ^org_id or rp.visibility == "public",
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
        skill_count: count(rs.id),
        organization_id: rp.organization_id
      }
    )
    |> Repo.all()
  end

  # --- Clone ---

  def clone_role_skills(org_id, role_profile_ids) when is_list(role_profile_ids) do
    profiles =
      from(rp in RoleProfile,
        where:
          (rp.organization_id == ^org_id or rp.visibility == "public") and
            rp.id in ^role_profile_ids,
        preload: [role_skills: :skill]
      )
      |> Repo.all()

    # Union skills, keep highest required_level on overlap (keyed by skill.id —
    # ESCO contains distinct skills sharing a preferredLabel, so identity-by-name
    # would silently merge them).
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
    |> Map.values()
    |> Enum.sort_by(&{&1.category, &1.cluster, &1.skill_name})
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
    |> Map.values()
    |> Enum.sort_by(&{&1.category, &1.cluster, &1.skill_name})
  end

  defp normalize_levels(nil), do: []
  defp normalize_levels([]), do: []

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

  defp get_level_field(_, _), do: nil

  # --- Version Currency ---

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

  defp maybe_include_public_roles(query, org_id, true) do
    from(rp in query,
      where: rp.organization_id == ^org_id or rp.visibility == "public"
    )
  end

  defp maybe_include_public_roles(query, org_id, false) do
    from(rp in query, where: rp.organization_id == ^org_id)
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
