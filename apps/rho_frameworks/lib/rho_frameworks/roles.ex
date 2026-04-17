defmodule RhoFrameworks.Roles do
  @moduledoc "Context for role profile CRUD, skill assignments, comparison, and career ladders."

  require Logger
  import Ecto.Query
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Frameworks.{Library, RoleProfile, RoleSkill}
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

  @doc "Fetch a role profile visible to the org: own role or one belonging to a public library."
  def get_visible_role_profile!(org_id, id) do
    case get_role_profile(org_id, id) do
      nil ->
        Repo.one!(
          from(rp in RoleProfile,
            join: lib in Library,
            on: lib.id == rp.library_id,
            where: rp.id == ^id and lib.visibility == "public"
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
    library_id =
      Keyword.get_lazy(opts, :library_id, fn ->
        Lib.get_or_create_default_library(org_id).id
      end)

    # Look up library to stamp version
    library = Repo.get(RhoFrameworks.Frameworks.Library, library_id)
    library_version = if library, do: library.version || "draft", else: nil

    Ecto.Multi.new()
    |> Ecto.Multi.run(:skills, fn _repo, _ ->
      resolve_fn =
        if library && library.immutable do
          # Immutable library — look up existing skills by name, don't upsert
          fn row ->
            name = row[:skill_name] || row["skill_name"] || row[:name] || row["name"]
            slug = RhoFrameworks.Frameworks.Skill.slugify(name)

            case Repo.get_by(RhoFrameworks.Frameworks.Skill,
                   library_id: library_id,
                   slug: slug
                 ) do
              nil -> {:error, "Skill '#{name}' not found in immutable library"}
              skill -> {:ok, skill}
            end
          end
        else
          # Mutable library — upsert as before
          fn row ->
            Lib.upsert_skill(library_id, %{
              category: row[:category] || row["category"] || "",
              cluster: row[:cluster] || row["cluster"] || "",
              name: row[:skill_name] || row["skill_name"] || row[:name] || row["name"],
              description:
                Map.get(row, :skill_description, Map.get(row, "skill_description", "")),
              status: "draft"
            })
          end
        end

      results =
        Enum.reduce_while(role_rows, {:ok, []}, fn row, {:ok, acc} ->
          case resolve_fn.(row) do
            {:ok, skill} -> {:cont, {:ok, [{skill, row} | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      case results do
        {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Ecto.Multi.run(:role_profile, fn repo, _ ->
      rp_attrs =
        attrs
        |> Map.put(:organization_id, org_id)
        |> Map.put(:library_id, library_id)
        |> Map.put(:library_version, library_version)

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

            {name, MapSet.difference(skills, others) |> MapSet.to_list() |> Enum.sort()}
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
          total_unique_skills: MapSet.size(all_skills),
          shared_skills: shared |> MapSet.to_list() |> Enum.sort(),
          shared_count: MapSet.size(shared),
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

  def find_similar_roles(org_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    # Fetch all roles visible to the org (own + public) with their skill counts
    candidates =
      from(rp in RoleProfile,
        left_join: lib in Library,
        on: lib.id == rp.library_id,
        where: rp.organization_id == ^org_id or lib.visibility == "public",
        left_join: rs in RoleSkill,
        on: rs.role_profile_id == rp.id,
        group_by: rp.id,
        select: %{
          id: rp.id,
          name: rp.name,
          role_family: rp.role_family,
          seniority_label: rp.seniority_label,
          skill_count: count(rs.id)
        }
      )
      |> Repo.all()

    case candidates do
      [] ->
        []

      _ ->
        case rank_similar_via_llm(candidates, query, limit) do
          {:ok, ranked_ids} ->
            Logger.warning(
              "[find_similar_roles] LLM returned #{length(ranked_ids)} ids: #{inspect(ranked_ids)}"
            )

            id_index = Map.new(candidates, &{&1.id, &1})
            Enum.flat_map(ranked_ids, fn id -> if m = id_index[id], do: [m], else: [] end)

          {:error, reason} ->
            Logger.warning(
              "[find_similar_roles] LLM failed: #{inspect(reason)}, falling back to LIKE"
            )

            find_similar_roles_fallback(org_id, query, limit)
        end
    end
  end

  defp rank_similar_via_llm(candidates, query, limit) do
    # Use short indices so the LLM doesn't hallucinate large DB ids
    indexed = Enum.with_index(candidates, 1)

    role_list =
      Enum.map_join(indexed, "\n", fn {c, idx} ->
        "#{idx}. #{c.name} (family: #{c.role_family || "N/A"}, seniority: #{c.seniority_label || "N/A"})"
      end)

    schema = %{
      type: "object",
      properties: %{
        indices: %{
          type: "array",
          items: %{type: "integer"},
          description:
            "1-based indices of the most similar roles from the list, ordered by relevance"
        }
      },
      required: ["indices"]
    }

    messages = [
      ReqLLM.Context.system("""
      You are a role matching assistant. Given a query and a numbered list of existing role profiles,
      return the numbers of the most similar roles ordered by relevance.
      Consider semantic similarity — e.g. "Software Engineer" matches "Backend Developer",
      "Full Stack Engineer", etc. Return at most #{limit} numbers.
      Only return numbers that appear in the list. If nothing is similar, return an empty array.
      """),
      ReqLLM.Context.user("""
      Query: #{query}

      Existing roles:
      #{role_list}
      """)
    ]

    config = Rho.Config.agent_config()
    model = config.model
    gen_opts = build_llm_gen_opts(config[:provider])

    idx_to_id = Map.new(indexed, fn {c, idx} -> {idx, c.id} end)

    case ReqLLM.generate_object(model, messages, schema, gen_opts ++ [max_tokens: 1024]) do
      {:ok, response} ->
        case ReqLLM.Response.object(response) do
          %{"indices" => idxs} when is_list(idxs) ->
            ids = Enum.flat_map(idxs, fn i -> if id = idx_to_id[i], do: [id], else: [] end)
            {:ok, ids}

          _ ->
            {:error, :unexpected_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_llm_gen_opts(nil), do: []

  defp build_llm_gen_opts(provider) do
    [provider_options: [openrouter_provider: provider]]
  end

  defp find_similar_roles_fallback(org_id, query, limit) do
    pattern = "%#{sanitize_query(query)}%"

    from(rp in RoleProfile,
      left_join: lib in Library,
      on: lib.id == rp.library_id,
      where: rp.organization_id == ^org_id or lib.visibility == "public",
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

  # --- Version Currency ---

  @doc """
  Check if a role profile's skills are current relative to the latest
  published library version. Returns {:ok, :current} | {:stale, diff}.
  """
  def check_version_currency(org_id, role_profile_id) do
    case get_role_profile(org_id, role_profile_id) do
      nil ->
        {:error, :not_found}

      %{library_id: nil} ->
        {:error, :no_library, "Role profile has no linked library"}

      rp ->
        library = Repo.get(RhoFrameworks.Frameworks.Library, rp.library_id)

        if is_nil(library) do
          {:error, :library_deleted, "Linked library no longer exists"}
        else
          latest = Lib.get_latest_version(org_id, library.name)

          cond do
            is_nil(latest) ->
              {:ok, :current, %{note: "No published versions — role is against a draft"}}

            rp.library_version == latest.version ->
              {:ok, :current, %{version: latest.version}}

            true ->
              # Get diff between role's version and latest
              diff_result =
                Lib.diff_versions(org_id, library.name, rp.library_version, latest.version)

              case diff_result do
                {:ok, diff} ->
                  {:stale,
                   %{
                     role_version: rp.library_version,
                     latest_version: latest.version,
                     diff: diff
                   }}

                {:error, _, _} ->
                  {:stale,
                   %{
                     role_version: rp.library_version,
                     latest_version: latest.version,
                     diff: nil
                   }}
              end
          end
        end
    end
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

  defp maybe_include_public_roles(query, org_id, true) do
    from(rp in query,
      left_join: lib in Library,
      on: lib.id == rp.library_id,
      where: rp.organization_id == ^org_id or lib.visibility == "public"
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
