defmodule RhoFrameworks.Library do
  @moduledoc "Context for library CRUD, skills, immutability, forking, and deduplication."

  import Ecto.Query
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Frameworks.{Library, Skill, RoleProfile, RoleSkill, DuplicateDismissal}

  # --- Library CRUD ---

  def list_libraries(org_id, opts \\ []) do
    type = Keyword.get(opts, :type)
    exclude_immutable = Keyword.get(opts, :exclude_immutable, false)

    from(l in Library,
      where: l.organization_id == ^org_id,
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
        skill_count: count(s.id),
        updated_at: l.updated_at
      }
    )
    |> maybe_filter_type(type)
    |> maybe_exclude_immutable(exclude_immutable)
    |> Repo.all()
  end

  def get_library(org_id, id) do
    Repo.get_by(Library, id: id, organization_id: org_id)
  end

  def get_library!(org_id, id) do
    Repo.get_by!(Library, id: id, organization_id: org_id)
  end

  def delete_library(org_id, id) do
    case get_library(org_id, id) do
      nil -> {:error, :not_found}
      lib -> Repo.delete(lib)
    end
  end

  def create_library(org_id, attrs) do
    %Library{}
    |> Library.changeset(Map.put(attrs, :organization_id, org_id))
    |> Repo.insert()
  end

  def get_or_create_default_library(org_id) do
    case Repo.get_by(Library, organization_id: org_id, name: "Default Skills") do
      nil ->
        {:ok, lib} =
          create_library(org_id, %{
            name: "Default Skills",
            description: "Auto-created default skill library"
          })

        lib

      lib ->
        lib
    end
  end

  # --- Immutability ---

  defp maybe_check_mutable(library, opts) do
    if Keyword.get(opts, :skip_mutability, false), do: :ok, else: ensure_mutable!(library)
  end

  def ensure_mutable!(%Library{immutable: true, name: name}) do
    {:error, :immutable_library,
     "Cannot modify '#{name}' — it is a standard framework. " <>
       "Fork it with fork_library to create a mutable working copy."}
  end

  def ensure_mutable!(%Library{immutable: false}), do: :ok

  # --- Skills ---

  def list_skills(library_id, opts \\ []) do
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

  def upsert_skill(library_id, attrs, opts \\ []) do
    library = Repo.get!(Library, library_id)

    with :ok <- maybe_check_mutable(library, opts) do
      name = attrs[:name] || attrs["name"]
      slug = Skill.slugify(name)

      case Repo.get_by(Skill, library_id: library_id, slug: slug) do
        nil ->
          %Skill{}
          |> Skill.changeset(Map.merge(attrs, %{library_id: library_id}))
          |> Repo.insert()

        existing ->
          # Don't downgrade published to draft
          attrs =
            if existing.status == "published" do
              Map.delete(attrs, :status) |> Map.delete("status")
            else
              attrs
            end

          existing
          |> Skill.changeset(Map.drop(attrs, [:library_id, "library_id"]))
          |> Repo.update()
      end
    end
  end

  # --- Save to Library (structured skill maps) ---

  def save_to_library(library_id, skills) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:skills, fn _repo, _ ->
      results =
        Enum.map(skills, fn skill_map ->
          {:ok, skill} =
            upsert_skill(library_id, %{
              category: skill_map[:category] || skill_map["category"] || "",
              cluster: skill_map[:cluster] || skill_map["cluster"] || "",
              name: skill_map[:skill_name] || skill_map["skill_name"],
              description: skill_map[:skill_description] || skill_map["skill_description"] || "",
              proficiency_levels:
                skill_map[:proficiency_levels] || skill_map["proficiency_levels"] || [],
              status: "published"
            })

          skill
        end)

      {:ok, results}
    end)
    |> Repo.transaction()
  end

  @doc "Load a library as structured skill maps (with nested proficiency_levels)."
  def load_library_rows(library_id, opts \\ []) do
    list_skills(library_id, opts)
    |> Enum.map(fn skill ->
      %{
        category: skill.category || "",
        cluster: skill.cluster || "",
        skill_name: skill.name,
        skill_description: skill.description || "",
        proficiency_levels: skill.proficiency_levels || []
      }
    end)
  end

  # --- Browse Library ---

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

  # --- Search ---

  def search_skills(library_id, query, opts \\ []) do
    category = Keyword.get(opts, :category)
    limit = Keyword.get(opts, :limit, 50)
    pattern = "%#{sanitize_query(query)}%"

    from(s in Skill,
      where: s.library_id == ^library_id,
      where:
        like(s.name, ^pattern) or
          like(s.description, ^pattern) or
          like(s.category, ^pattern) or
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
    pattern = "%#{sanitize_query(query)}%"

    from(s in Skill,
      join: l in Library,
      on: s.library_id == l.id,
      where: l.organization_id == ^org_id,
      where:
        like(s.name, ^pattern) or
          like(s.description, ^pattern) or
          like(s.category, ^pattern),
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
    |> maybe_filter(:category, category)
    |> Repo.all()
  end

  # --- Fork / Derive ---

  def fork_library(org_id, source_library_id, new_name, opts \\ []) do
    derive_library(org_id, [source_library_id], new_name, opts)
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

  def copy_skill(skill, target_library_id, opts \\ []) do
    source_skill_id = Keyword.get(opts, :source_skill_id)
    slug = Skill.slugify(skill.name)

    attrs = %{
      name: skill.name,
      description: skill.description,
      category: skill.category,
      cluster: skill.cluster,
      status: skill.status,
      sort_order: skill.sort_order,
      metadata: skill.metadata,
      proficiency_levels: skill.proficiency_levels,
      library_id: target_library_id,
      source_skill_id: source_skill_id
    }

    case Repo.get_by(Skill, library_id: target_library_id, slug: slug) do
      nil ->
        %Skill{}
        |> Skill.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> Skill.changeset(Map.drop(attrs, [:library_id]))
        |> Repo.update()
    end
  end

  defp copy_role_profile(role, org_id, skill_id_map, opts) do
    fork_name = Keyword.get(opts, :fork_name)

    name =
      if fork_name, do: "#{role.name} (#{fork_name})", else: role.name

    Ecto.Multi.new()
    |> Ecto.Multi.run(:role_profile, fn _repo, _ ->
      %RoleProfile{}
      |> RoleProfile.changeset(%{
        name: name,
        role_family: role.role_family,
        seniority_level: role.seniority_level,
        seniority_label: role.seniority_label,
        description: role.description,
        purpose: role.purpose,
        accountabilities: role.accountabilities,
        success_metrics: role.success_metrics,
        qualifications: role.qualifications,
        reporting_context: role.reporting_context,
        headcount: role.headcount,
        metadata: role.metadata,
        work_activities: role.work_activities,
        immutable: false,
        source_role_profile_id: role.id,
        organization_id: org_id
      })
      |> Repo.insert()
    end)
    |> Ecto.Multi.run(:role_skills, fn repo, %{role_profile: new_rp} ->
      entries =
        role.role_skills
        |> Enum.filter(fn rs -> Map.has_key?(skill_id_map, rs.skill_id) end)
        |> Enum.map(fn rs ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          %{
            id: Ecto.UUID.generate(),
            role_profile_id: new_rp.id,
            skill_id: skill_id_map[rs.skill_id].id,
            min_expected_level: rs.min_expected_level,
            weight: rs.weight,
            required: rs.required,
            inserted_at: now,
            updated_at: now
          }
        end)

      {count, _} = repo.insert_all(RoleSkill, entries)
      {:ok, count}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{role_profile: rp}} -> {:ok, rp}
      error -> error
    end
  end

  # --- Diff ---

  def diff_against_source(org_id, library_id) do
    lib = get_library!(org_id, library_id) |> Repo.preload(:derived_from)

    unless lib.derived_from_id do
      {:error, :no_source, "This library was not forked from another library."}
    else
      source_skills = list_skills(lib.derived_from_id) |> Map.new(&{&1.id, &1})
      fork_skills = list_skills(library_id)
      fork_by_source = Map.new(fork_skills, fn s -> {s.source_skill_id, s} end)

      added =
        fork_skills
        |> Enum.filter(&is_nil(&1.source_skill_id))
        |> Enum.map(& &1.name)

      removed =
        source_skills
        |> Enum.reject(fn {id, _} -> Map.has_key?(fork_by_source, id) end)
        |> Enum.map(fn {_, s} -> s.name end)

      modified =
        fork_by_source
        |> Enum.filter(fn {src_id, fork_s} ->
          src_id && Map.has_key?(source_skills, src_id) &&
            skill_modified?(source_skills[src_id], fork_s)
        end)
        |> Enum.map(fn {_, s} -> s.name end)

      unchanged_count =
        length(fork_skills) - length(added) - length(modified)

      {:ok,
       %{
         added: added,
         removed: removed,
         modified: modified,
         unchanged_count: max(unchanged_count, 0)
       }}
    end
  end

  defp skill_modified?(source, fork) do
    source.name != fork.name ||
      source.description != fork.description ||
      source.proficiency_levels != fork.proficiency_levels
  end

  # --- Combine Libraries ---

  def combine_libraries(org_id, source_library_ids, new_name, opts \\ [])
      when is_list(source_library_ids) do
    derive_library(org_id, source_library_ids, new_name, opts)
    |> case do
      {:ok, %{library: lib, skills: skill_map}} ->
        {:ok, %{library: lib, skill_count: map_size(skill_map)}}

      error ->
        error
    end
  end

  # --- Derive Library (unified fork + combine) ---

  @doc """
  Create a new mutable library by copying skills from one or more source libraries.
  Sources are never modified. Slug-based dedup across sources keeps first seen.
  Optionally copies role profiles.

  Returns `{:ok, %{library: lib, skills: skill_id_map}}`.
  """
  def derive_library(org_id, source_library_ids, new_name, opts \\ [])
      when is_list(source_library_ids) do
    categories = Keyword.get(opts, :categories, :all)
    include_roles = Keyword.get(opts, :include_roles, true)
    description = Keyword.get(opts, :description)

    sources = Enum.map(source_library_ids, &get_library!(org_id, &1))

    desc =
      description ||
        case sources do
          [single] -> "Derived from #{single.name}"
          many -> "Combined from: #{Enum.map_join(many, ", ", & &1.name)}"
        end

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:library, fn _ ->
      Library.changeset(%Library{}, %{
        name: new_name,
        organization_id: org_id,
        type: hd(sources).type,
        immutable: false,
        derived_from_id: hd(sources).id,
        description: desc
      })
    end)
    |> Ecto.Multi.run(:skills, fn _repo, %{library: lib} ->
      all_skills =
        Enum.flat_map(sources, fn src ->
          list_skills(src.id, skills_filter_opts(categories))
        end)

      {copied, _seen} =
        Enum.reduce(all_skills, {[], %{}}, fn skill, {acc, slugs} ->
          slug = Skill.slugify(skill.name)

          case Map.get(slugs, slug) do
            nil ->
              {:ok, new_skill} = copy_skill(skill, lib.id, source_skill_id: skill.id)
              {[new_skill | acc], Map.put(slugs, slug, skill.description)}

            existing_desc when existing_desc == skill.description ->
              {acc, slugs}

            _different_desc ->
              counter =
                Enum.count(slugs, fn {k, _} -> String.starts_with?(k, slug <> "-") end) + 2

              disambiguated_name = "#{skill.name} (#{counter})"

              {:ok, new_skill} =
                copy_skill(%{skill | name: disambiguated_name}, lib.id, source_skill_id: skill.id)

              {[new_skill | acc],
               Map.put(slugs, Skill.slugify(disambiguated_name), skill.description)}
          end
        end)

      {:ok, Map.new(Enum.reverse(copied), &{&1.source_skill_id, &1})}
    end)
    |> Ecto.Multi.run(:role_profiles, fn _repo, %{skills: skill_id_map} ->
      if include_roles do
        source_roles =
          Enum.flat_map(sources, fn src ->
            list_role_profiles_for_library(src.id, skills_filter_opts(categories))
          end)

        copied =
          Enum.map(source_roles, fn role ->
            {:ok, rp} = copy_role_profile(role, org_id, skill_id_map, fork_name: new_name)
            rp
          end)

        {:ok, copied}
      else
        {:ok, []}
      end
    end)
    |> Repo.transaction()
  end

  # --- Import Library ---

  def import_library(org_id, skill_maps, opts \\ []) do
    name = Keyword.get(opts, :name, "Imported Library")
    description = Keyword.get(opts, :description)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:library, fn _repo, _ ->
      create_library(org_id, %{name: name, description: description})
    end)
    |> Ecto.Multi.run(:skills, fn _repo, %{library: lib} ->
      results =
        Enum.map(skill_maps, fn skill_map ->
          {:ok, skill} =
            upsert_skill(lib.id, %{
              category: skill_map[:category] || skill_map["category"] || "",
              cluster: skill_map[:cluster] || skill_map["cluster"] || "",
              name:
                skill_map[:skill_name] || skill_map["skill_name"] || skill_map[:name] ||
                  skill_map["name"],
              description:
                skill_map[:skill_description] || skill_map["skill_description"] ||
                  skill_map[:description] || skill_map["description"] || "",
              proficiency_levels:
                skill_map[:proficiency_levels] || skill_map["proficiency_levels"] || [],
              status: "published"
            })

          skill
        end)

      {:ok, results}
    end)
    |> Repo.transaction()
  end

  # --- Template Loading ---

  def load_template(org_id, source_key, template_data) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:library, fn _repo, _ ->
      create_library(org_id, %{
        name: template_data.name,
        description: template_data[:description],
        immutable: true,
        source_key: source_key
      })
    end)
    |> Ecto.Multi.run(:skills, fn _repo, %{library: lib} ->
      results =
        Enum.map(template_data.skills, fn skill_map ->
          {:ok, skill} =
            upsert_skill(
              lib.id,
              %{
                category: skill_map[:category] || skill_map["category"] || "",
                cluster: skill_map[:cluster] || skill_map["cluster"] || "",
                name: skill_map[:name] || skill_map["name"],
                description: skill_map[:description] || skill_map["description"] || "",
                proficiency_levels:
                  skill_map[:proficiency_levels] || skill_map["proficiency_levels"] || [],
                status: "published"
              },
              skip_mutability: true
            )

          skill
        end)

      {:ok, results}
    end)
    |> Ecto.Multi.run(:role_profiles, fn _repo, %{library: lib, skills: skills} ->
      role_profile_defs = template_data[:role_profiles] || template_data["role_profiles"] || []

      if role_profile_defs == [] do
        {:ok, []}
      else
        # Build skill name → skill lookup from the just-created skills
        skill_by_name = Map.new(skills, fn skill -> {skill.name, skill} end)

        results =
          Enum.map(role_profile_defs, fn rp_def ->
            create_template_role_profile(org_id, lib, rp_def, skill_by_name)
          end)

        {:ok, results}
      end
    end)
    |> Repo.transaction()
  end

  defp create_template_role_profile(org_id, _library, rp_def, skill_by_name) do
    {:ok, rp} =
      %RoleProfile{}
      |> RoleProfile.changeset(%{
        name: rp_def.name || rp_def["name"],
        role_family: rp_def[:role_family] || rp_def["role_family"],
        seniority_level: rp_def[:seniority_level] || rp_def["seniority_level"],
        seniority_label: rp_def[:seniority_label] || rp_def["seniority_label"],
        purpose: rp_def[:purpose] || rp_def["purpose"],
        immutable: true,
        organization_id: org_id
      })
      |> Repo.insert()

    skill_defs = rp_def[:skills] || rp_def["skills"] || []

    Enum.each(skill_defs, fn skill_def ->
      skill_name = skill_def[:skill_name] || skill_def["skill_name"]
      skill = Map.get(skill_by_name, skill_name)

      if skill do
        %RoleSkill{}
        |> RoleSkill.changeset(%{
          role_profile_id: rp.id,
          skill_id: skill.id,
          min_expected_level:
            skill_def[:min_expected_level] || skill_def["min_expected_level"] || 1,
          weight: 1.0,
          required: Map.get(skill_def, :required, Map.get(skill_def, "required", true))
        })
        |> Repo.insert!()
      end
    end)

    rp
  end

  # --- Deduplication ---

  def find_duplicates(library_id, opts \\ []) do
    depth = Keyword.get(opts, :depth, :standard)

    skills = list_skills(library_id)
    dismissed = list_dismissed_pairs(library_id)

    candidates =
      find_slug_prefix_overlaps(skills) ++ find_word_overlap_in_category(skills)

    candidates =
      if depth == :deep do
        candidates ++ find_semantic_duplicates_via_llm(skills)
      else
        candidates
      end

    candidates
    |> deduplicate_pairs()
    |> reject_dismissed(dismissed)
    |> enrich_with_role_references()
    |> Enum.sort_by(fn c -> -confidence_score(c.confidence) end)
  end

  def merge_skills(source_id, target_id, opts \\ []) do
    source = Repo.get!(Skill, source_id) |> Repo.preload(:library)
    target = Repo.get!(Skill, target_id) |> Repo.preload(:library)

    with :ok <- ensure_mutable!(source.library),
         :ok <- ensure_mutable!(target.library) do
      new_name = Keyword.get(opts, :new_name)
      conflict_strategy = Keyword.get(opts, :on_conflict, :keep_higher)

      source_refs = Repo.all(from(rs in RoleSkill, where: rs.skill_id == ^source_id))

      target_ref_map =
        Repo.all(from(rs in RoleSkill, where: rs.skill_id == ^target_id))
        |> Map.new(&{&1.role_profile_id, &1})

      {clean, conflicted} =
        Enum.split_with(source_refs, fn rs ->
          not Map.has_key?(target_ref_map, rs.role_profile_id)
        end)

      Ecto.Multi.new()
      |> Ecto.Multi.run(:repoint, fn _repo, _ ->
        Enum.each(clean, fn rs ->
          rs |> Ecto.Changeset.change(%{skill_id: target_id}) |> Repo.update!()
        end)

        {:ok, length(clean)}
      end)
      |> Ecto.Multi.run(:conflicts, fn _repo, _ ->
        results =
          Enum.map(conflicted, fn source_rs ->
            target_rs = target_ref_map[source_rs.role_profile_id]
            resolve_conflict(source_rs, target_rs, conflict_strategy)
          end)

        {:ok, results}
      end)
      |> Ecto.Multi.run(:levels, fn _repo, _ ->
        {:ok, merge_proficiency_levels(source, target)}
      end)
      |> Ecto.Multi.run(:rename, fn _repo, _ ->
        if new_name do
          target |> Skill.changeset(%{name: new_name}) |> Repo.update()
        else
          {:ok, nil}
        end
      end)
      |> Ecto.Multi.run(:delete_source, fn _repo, _ ->
        # Delete orphaned source role_skills first
        from(rs in RoleSkill, where: rs.skill_id == ^source_id) |> Repo.delete_all()
        Repo.delete(source)
      end)
      |> Repo.transaction()
    end
  end

  def dismiss_duplicate(library_id, skill_a_id, skill_b_id) do
    {id_a, id_b} =
      if skill_a_id < skill_b_id, do: {skill_a_id, skill_b_id}, else: {skill_b_id, skill_a_id}

    %DuplicateDismissal{}
    |> DuplicateDismissal.changeset(%{library_id: library_id, skill_a_id: id_a, skill_b_id: id_b})
    |> Repo.insert(on_conflict: :nothing)
  end

  def consolidation_report(library_id) do
    skills = list_skills(library_id) |> Repo.preload(:role_skills)
    duplicates = find_duplicates(library_id)

    drafts =
      skills
      |> Enum.filter(&(&1.status == "draft"))
      |> Enum.sort_by(fn s -> -length(s.role_skills) end)
      |> Enum.map(fn s ->
        %{id: s.id, name: s.name, role_count: length(s.role_skills)}
      end)

    orphans =
      skills
      |> Enum.filter(fn s -> s.role_skills == [] end)
      |> Enum.map(fn s -> %{id: s.id, name: s.name, status: s.status} end)

    %{
      total_skills: length(skills),
      duplicate_pairs: duplicates,
      drafts: drafts,
      orphans: orphans
    }
  end

  # --- LLM-based semantic dedup ---

  defp find_semantic_duplicates_via_llm(skills) when length(skills) < 2, do: []

  defp find_semantic_duplicates_via_llm(skills) do
    skill_index = Map.new(skills, fn s -> {s.id, s} end)

    skill_list =
      skills
      |> Enum.map(fn s ->
        desc = if s.description && s.description != "", do: " — #{s.description}", else: ""
        "- [#{s.id}] #{s.name} (#{s.category})#{desc}"
      end)
      |> Enum.join("\n")

    task_prompt = """
    Below is a list of skills from a single competency library.
    Identify pairs that are semantically the same competency despite different names.

    Only flag pairs where you are confident they describe the same underlying skill.
    Do NOT flag pairs that are related but distinct (e.g., "Data Analysis" and "Statistical Analysis"
    are different if one focuses on exploratory work and the other on hypothesis testing).

    Skills:
    #{skill_list}

    Call the finish tool with a JSON array of objects with keys "id_a" and "id_b" (the skill IDs from the brackets).
    If no semantic duplicates are found, return an empty array: []
    """

    tools = [Rho.Stdlib.Tools.Finish.tool_def()]

    {:ok, agent_id} =
      Rho.Agent.LiteWorker.start(
        task: task_prompt,
        parent_agent_id: "dedup-#{Ecto.UUID.generate()}",
        role: :spreadsheet,
        system_prompt:
          "You are a competency framework expert that identifies semantically duplicate skills. " <>
            "Always call the finish tool with your result.",
        tools: tools,
        max_steps: 1
      )

    case Rho.Agent.LiteWorker.await(agent_id, 60_000) do
      {:ok, text} ->
        parse_semantic_pairs(text, skill_index)

      {:error, _reason} ->
        []
    end
  end

  defp parse_semantic_pairs(text, skill_index) do
    case Rho.StructuredOutput.parse(text) do
      {:ok, pairs} when is_list(pairs) ->
        pairs
        |> Enum.filter(fn p ->
          id_a = p["id_a"]
          id_b = p["id_b"]
          id_a && id_b && Map.has_key?(skill_index, id_a) && Map.has_key?(skill_index, id_b)
        end)
        |> Enum.map(fn p ->
          a = skill_index[p["id_a"]]
          b = skill_index[p["id_b"]]
          {sa, sb} = if a.id < b.id, do: {a, b}, else: {b, a}

          %{
            skill_a: %{id: sa.id, name: sa.name, category: sa.category},
            skill_b: %{id: sb.id, name: sb.name, category: sb.category},
            confidence: :low,
            detection_method: :semantic
          }
        end)

      _ ->
        []
    end
  end

  # --- Private helpers ---

  defp enrich_with_role_references(candidates) do
    skill_ids =
      Enum.flat_map(candidates, fn c -> [c.skill_a.id, c.skill_b.id] end)
      |> Enum.uniq()

    role_refs =
      from(rs in RoleSkill,
        join: rp in RoleProfile,
        on: rs.role_profile_id == rp.id,
        where: rs.skill_id in ^skill_ids,
        select: {rs.skill_id, rp.name, rs.min_expected_level}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_, name, level} -> {name, level} end)

    Enum.map(candidates, fn c ->
      refs_a = Map.get(role_refs, c.skill_a.id, [])
      refs_b = Map.get(role_refs, c.skill_b.id, [])

      role_names_a = Enum.map(refs_a, &elem(&1, 0))
      role_names_b = Enum.map(refs_b, &elem(&1, 0))

      # level_conflict: true if any shared role has different levels for the two skills
      shared_roles = MapSet.intersection(MapSet.new(role_names_a), MapSet.new(role_names_b))

      level_conflict =
        Enum.any?(shared_roles, fn role ->
          level_a = refs_a |> Enum.find(fn {n, _} -> n == role end) |> elem(1)
          level_b = refs_b |> Enum.find(fn {n, _} -> n == role end) |> elem(1)
          level_a != level_b
        end)

      Map.merge(c, %{
        roles_a: role_names_a,
        roles_b: role_names_b,
        level_conflict: level_conflict
      })
    end)
  end

  defp list_dismissed_pairs(library_id) do
    from(d in DuplicateDismissal, where: d.library_id == ^library_id)
    |> Repo.all()
    |> Enum.map(fn d -> {d.skill_a_id, d.skill_b_id} end)
    |> MapSet.new()
  end

  defp find_slug_prefix_overlaps(skills) do
    slugs = Enum.map(skills, fn s -> {s.id, s.slug, s.name, s.category} end)

    for {id_a, slug_a, name_a, cat_a} <- slugs,
        {id_b, slug_b, name_b, cat_b} <- slugs,
        id_a < id_b,
        shared_prefix_length(slug_a, slug_b) >= 3 do
      %{
        skill_a: %{id: id_a, name: name_a, category: cat_a},
        skill_b: %{id: id_b, name: name_b, category: cat_b},
        confidence: :high,
        detection_method: :slug_prefix
      }
    end
  end

  defp find_word_overlap_in_category(skills) do
    by_cat = Enum.group_by(skills, & &1.category)

    Enum.flat_map(by_cat, fn {_cat, cat_skills} ->
      for a <- cat_skills,
          b <- cat_skills,
          a.id < b.id,
          jaccard_similarity(a.name, b.name) >= 0.5 do
        %{
          skill_a: %{id: a.id, name: a.name, category: a.category},
          skill_b: %{id: b.id, name: b.name, category: b.category},
          confidence: :medium,
          detection_method: :word_overlap
        }
      end
    end)
  end

  defp shared_prefix_length(a, b) do
    a
    |> String.graphemes()
    |> Enum.zip(String.graphemes(b))
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> length()
  end

  defp jaccard_similarity(a, b) do
    words_a = a |> String.downcase() |> String.split(~r/\s+/) |> MapSet.new()
    words_b = b |> String.downcase() |> String.split(~r/\s+/) |> MapSet.new()
    inter = MapSet.intersection(words_a, words_b) |> MapSet.size()
    union = MapSet.union(words_a, words_b) |> MapSet.size()
    if union == 0, do: 0.0, else: inter / union
  end

  defp deduplicate_pairs(candidates) do
    candidates
    |> Enum.uniq_by(fn c ->
      ids = [c.skill_a.id, c.skill_b.id] |> Enum.sort()
      {Enum.at(ids, 0), Enum.at(ids, 1)}
    end)
  end

  defp reject_dismissed(candidates, dismissed) do
    Enum.reject(candidates, fn c ->
      {id_a, id_b} =
        if c.skill_a.id < c.skill_b.id,
          do: {c.skill_a.id, c.skill_b.id},
          else: {c.skill_b.id, c.skill_a.id}

      MapSet.member?(dismissed, {id_a, id_b})
    end)
  end

  defp confidence_score(:high), do: 3
  defp confidence_score(:medium), do: 2
  defp confidence_score(:low), do: 1

  defp resolve_conflict(source_rs, target_rs, :keep_higher) do
    if source_rs.min_expected_level > target_rs.min_expected_level do
      target_rs
      |> Ecto.Changeset.change(%{min_expected_level: source_rs.min_expected_level})
      |> Repo.update!()
    end

    Repo.delete!(source_rs)
    :resolved
  end

  defp resolve_conflict(source_rs, _target_rs, :keep_target) do
    Repo.delete!(source_rs)
    :resolved
  end

  defp resolve_conflict(source_rs, target_rs, :flag) do
    {:conflict, source_rs, target_rs}
  end

  defp merge_proficiency_levels(source, target) do
    source_levels =
      Map.new(source.proficiency_levels || [], fn l -> {l["level"] || l[:level], l} end)

    target_levels =
      Map.new(target.proficiency_levels || [], fn l -> {l["level"] || l[:level], l} end)

    merged = Map.merge(source_levels, target_levels)
    gaps = map_size(merged) - map_size(target_levels)

    if gaps > 0 do
      sorted = merged |> Map.values() |> Enum.sort_by(fn l -> l["level"] || l[:level] end)
      target |> Skill.changeset(%{proficiency_levels: sorted}) |> Repo.update!()
    end

    %{filled: gaps, total: map_size(merged)}
  end

  defp maybe_filter_type(query, nil), do: query

  defp maybe_filter_type(query, type) do
    from(l in query, where: l.type == ^type)
  end

  defp maybe_exclude_immutable(query, false), do: query

  defp maybe_exclude_immutable(query, true) do
    from(l in query, where: l.immutable == false)
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

  defp skills_filter_opts(:all), do: []
  defp skills_filter_opts(categories) when is_list(categories), do: [categories: categories]
  defp skills_filter_opts(_), do: []

  defp sanitize_query(query) do
    query
    |> String.replace(~r/[^\w\s]/, "")
    |> String.trim()
  end
end
