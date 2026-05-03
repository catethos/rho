defmodule RhoFrameworks.Library do
  @moduledoc "Context for library CRUD, skills, immutability, forking, and deduplication."

  import Ecto.Query
  require Logger
  alias RhoFrameworks.Repo

  alias RhoFrameworks.Frameworks.{
    Library,
    Skill,
    RoleProfile,
    RoleSkill,
    DuplicateDismissal,
    ResearchNote
  }

  # --- Library CRUD ---

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

  @doc """
  Returns a compact summary of all libraries and their skill names for an org.
  Designed for prompt injection — lightweight query, no proficiency data.
  """
  def library_summary(org_id) do
    # Skip public libraries: ESCO has 14k skills and naive enumeration blows
    # agent prompt budgets. Agents discover public skills via
    # `search_skills_across/3` instead.
    libraries = list_libraries(org_id, include_public: false)

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

      Enum.map(libraries, fn lib ->
        skills = Map.get(skills_by_library, lib.id, [])
        by_category = Enum.group_by(skills, & &1.category)

        %{
          id: lib.id,
          name: lib.name,
          skill_count: lib.skill_count,
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
  end

  @doc """
  List archived research notes for a library, newest first.

  Returns the rows persisted by `Workbench.save_framework/3` from the
  pinned subset of the session's `research_notes` named table. Read-only.
  """
  def list_research_notes(library_id) when is_binary(library_id) do
    from(n in ResearchNote,
      where: n.library_id == ^library_id,
      order_by: [desc: n.inserted_at]
    )
    |> Repo.all()
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

  @doc "Fetch a library visible to the org: own library or any public library."
  def get_visible_library!(org_id, id) do
    get_library(org_id, id) || get_public_library!(id)
  end

  @doc "Fetch a public library by id (no org scoping). Raises if not found or not public."
  def get_public_library!(id) do
    Repo.get_by!(Library, id: id, visibility: "public")
  end

  def rename_library(org_id, library_id, new_name) do
    with lib when not is_nil(lib) <- get_library(org_id, library_id),
         :ok <- ensure_mutable!(lib) do
      lib
      |> Library.changeset(%{name: new_name})
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      error -> error
    end
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

  # --- Versioning ---

  @doc """
  Compute the next version tag for a library: YYYY.N where N increments per year.
  """
  def next_version_tag(org_id, library_name) do
    year = Date.utc_today().year

    latest_n =
      from(l in Library,
        where:
          l.organization_id == ^org_id and
            l.name == ^library_name and
            like(l.version, ^"#{year}.%"),
        select: l.version
      )
      |> Repo.all()
      |> Enum.map(fn v ->
        case String.split(v, ".") do
          [_year, n] -> String.to_integer(n)
          _ -> 0
        end
      end)
      |> Enum.max(fn -> 0 end)

    "#{year}.#{latest_n + 1}"
  end

  @doc """
  Publish the current draft as a versioned snapshot.
  Freezes the library (immutable: true), stamps version + published_at.
  If version_tag is nil, auto-generates the next YYYY.N version.
  """
  def publish_version(org_id, library_id, version_tag \\ nil, opts \\ []) do
    notes = Keyword.get(opts, :notes)

    with %Library{} = lib <- get_library(org_id, library_id),
         true <- Library.draft?(lib) || {:error, :already_published, lib},
         version_tag <- version_tag || next_version_tag(org_id, lib.name),
         :ok <- validate_version_unique(org_id, lib.name, version_tag) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      metadata =
        if notes,
          do: Map.put(lib.metadata || %{}, "publish_notes", notes),
          else: lib.metadata

      lib
      |> Library.changeset(%{
        version: version_tag,
        published_at: now,
        immutable: true,
        metadata: metadata
      })
      |> Repo.update()
    else
      nil ->
        {:error, :not_found}

      {:error, :already_published, lib} ->
        {:error, :already_published,
         "Library is already published (version: #{lib.version}). Create a new draft to make changes."}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Create a new draft from the latest published version.
  Deep-copies all skills. Fails if a draft already exists for this library name.
  """
  def create_draft_from_latest(org_id, library_name, opts \\ []) do
    description = Keyword.get(opts, :description)

    with nil <- get_draft(org_id, library_name),
         %Library{} = source <- get_latest_version(org_id, library_name) do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:library, fn _ ->
        Library.changeset(%Library{}, %{
          name: library_name,
          organization_id: org_id,
          type: source.type,
          immutable: false,
          derived_from_id: source.id,
          description: description || source.description,
          metadata: source.metadata || %{}
        })
      end)
      |> Ecto.Multi.run(:skills, fn _repo, %{library: draft} ->
        {:ok, copy_all_skills(source.id, draft.id)}
      end)
      |> Ecto.Multi.run(:link_superseded, fn _repo, %{library: draft} ->
        source
        |> Library.changeset(%{superseded_by_id: draft.id})
        |> Repo.update()
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{library: draft, skills: skills}} ->
          {:ok, %{library: draft, skill_count: length(skills)}}

        {:error, step, reason, _} ->
          {:error, step, reason}
      end
    else
      %Library{} = _existing_draft ->
        {:error, :draft_exists,
         "A draft already exists for '#{library_name}'. Edit or publish it first."}

      nil ->
        {:error, :no_published_version,
         "No published version of '#{library_name}' found to create a draft from."}
    end
  end

  @doc "List all published versions of a library by name, newest first."
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

  @doc "Get the latest published version of a library by name."
  def get_latest_version(org_id, library_name) do
    from(l in Library,
      where: l.organization_id == ^org_id and l.name == ^library_name and not is_nil(l.version),
      order_by: [desc: l.published_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Get the default published version of a library by name, or nil."
  def get_default_version(org_id, library_name) do
    from(l in Library,
      where:
        l.organization_id == ^org_id and l.name == ^library_name and
          l.is_default == true and not is_nil(l.version),
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Set a published version as the default for its library name.
  Clears any previous default for the same (org, name).
  """
  def set_default_version(org_id, library_id) do
    with %Library{} = lib <- get_library(org_id, library_id),
         true <- Library.published?(lib) || {:error, :not_published} do
      Ecto.Multi.new()
      |> Ecto.Multi.update_all(
        :clear_previous,
        from(l in Library,
          where:
            l.organization_id == ^org_id and l.name == ^lib.name and
              l.is_default == true and l.id != ^lib.id
        ),
        set: [is_default: false]
      )
      |> Ecto.Multi.update(:set_default, Library.changeset(lib, %{is_default: true}))
      |> Repo.transaction()
      |> case do
        {:ok, %{set_default: lib}} -> {:ok, lib}
        {:error, _step, reason, _} -> {:error, reason}
      end
    else
      nil ->
        {:error, :not_found}

      {:error, :not_published} ->
        {:error, :not_published, "Only published versions can be set as default."}
    end
  end

  @doc "Get the current draft for a library name, or nil."
  def get_draft(org_id, library_name) do
    from(l in Library,
      where: l.organization_id == ^org_id and l.name == ^library_name and is_nil(l.version),
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Resolve a library by name + optional version.
  nil version → draft if exists, else default version, else latest published.
  """
  def resolve_library(org_id, library_name, version \\ nil)

  def resolve_library(org_id, library_name, nil) do
    by_name =
      from(l in Library,
        where: l.organization_id == ^org_id and l.name == ^library_name,
        order_by: [
          desc: is_nil(l.version),
          desc: l.is_default,
          desc: l.published_at
        ],
        limit: 1
      )
      |> Repo.one()

    by_name || get_library(org_id, library_name)
  end

  def resolve_library(org_id, library_name, version) do
    Repo.get_by(Library,
      organization_id: org_id,
      name: library_name,
      version: version
    )
  end

  @doc "Diff two versions of the same library. Returns added/removed/modified skills."
  def diff_versions(org_id, library_name, version_a, version_b) do
    lib_a = resolve_library(org_id, library_name, version_a)
    lib_b = resolve_library(org_id, library_name, version_b)

    cond do
      is_nil(lib_a) ->
        {:error, :not_found, "Version '#{version_a || "draft"}' not found"}

      is_nil(lib_b) ->
        {:error, :not_found, "Version '#{version_b || "draft"}' not found"}

      true ->
        skills_a = list_skills(lib_a.id) |> Map.new(&{&1.slug, &1})
        skills_b = list_skills(lib_b.id) |> Map.new(&{&1.slug, &1})

        slugs_a = Map.keys(skills_a) |> MapSet.new()
        slugs_b = Map.keys(skills_b) |> MapSet.new()

        added = MapSet.difference(slugs_b, slugs_a) |> Enum.map(&skills_b[&1].name)
        removed = MapSet.difference(slugs_a, slugs_b) |> Enum.map(&skills_a[&1].name)

        modified =
          MapSet.intersection(slugs_a, slugs_b)
          |> Enum.filter(fn slug -> skill_modified?(skills_a[slug], skills_b[slug]) end)
          |> Enum.map(&skills_a[&1].name)

        {:ok,
         %{
           version_a: version_a || "draft",
           version_b: version_b || "draft",
           added: added,
           removed: removed,
           modified: modified,
           unchanged_count: MapSet.size(MapSet.intersection(slugs_a, slugs_b)) - length(modified)
         }}
    end
  end

  defp validate_version_unique(org_id, name, version_tag) do
    case resolve_library(org_id, name, version_tag) do
      nil ->
        :ok

      _exists ->
        {:error, :version_exists, "Version '#{version_tag}' already exists for '#{name}'."}
    end
  end

  # --- Skills ---

  def list_skills(library_id, opts \\ [])
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

  def upsert_skill(library_id, attrs, opts \\ []) do
    library = Repo.get!(Library, library_id)

    with :ok <- maybe_check_mutable(library, opts) do
      slug = Skill.slugify(attrs[:name])

      case Repo.get_by(Skill, library_id: library_id, slug: slug) do
        nil ->
          attrs = add_embedding_attrs(attrs, nil)

          %Skill{}
          |> Skill.changeset(Map.merge(attrs, %{library_id: library_id}))
          |> Repo.insert()

        existing ->
          attrs =
            existing
            |> guard_status_downgrade(attrs)
            |> add_embedding_attrs(existing)

          existing
          |> Skill.changeset(Map.drop(attrs, [:library_id, "library_id"]))
          |> Repo.update()
      end
    end
  end

  # --- Batch upsert (private) ---
  #
  # Round-trip shape against Postgres:
  #   1. Pre-fetch existing slugs in `library_id`         (1 query)
  #   2. Bulk-embed any rows whose text hash changed      (≤1 embed_many call)
  #   3. `insert_all` for new rows                        (1 query, returning rows)
  #   4. Per-row update for existing rows                 (N_existing queries)
  # Net wins are biggest on first-save (N_existing = 0): N+2 round-trips → 2.

  defp bulk_upsert_skills(library_id, skill_attr_list, opts \\ []) do
    library = Repo.get!(Library, library_id)

    with :ok <- maybe_check_mutable(library, opts) do
      slugs = Enum.map(skill_attr_list, fn a -> Skill.slugify(a[:name]) end)

      existing =
        from(s in Skill, where: s.library_id == ^library_id and s.slug in ^slugs)
        |> Repo.all()
        |> Map.new(&{&1.slug, &1})

      attr_list_with_embeddings = add_embedding_attrs_bulk(skill_attr_list, existing)

      {to_insert, to_update} =
        Enum.split_with(attr_list_with_embeddings, fn attrs ->
          is_nil(Map.get(existing, Skill.slugify(attrs[:name])))
        end)

      inserted = bulk_insert_new_skills(to_insert, library_id)
      updated = Enum.map(to_update, &update_existing_skill(&1, existing))

      {:ok, inserted ++ updated}
    end
  end

  defp bulk_insert_new_skills([], _library_id), do: []

  defp bulk_insert_new_skills(attr_list, library_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows = Enum.map(attr_list, &build_insert_all_row(&1, library_id, now))

    {_n, returned} = Repo.insert_all(Skill, rows, returning: true)
    returned
  end

  defp build_insert_all_row(attrs, library_id, now) do
    name = attrs[:name]

    %{
      id: Ecto.UUID.generate(),
      library_id: library_id,
      slug: Skill.slugify(name),
      name: name,
      description: attrs[:description],
      category: attrs[:category] || "",
      cluster: attrs[:cluster],
      status: attrs[:status] || "draft",
      sort_order: attrs[:sort_order],
      metadata: attrs[:metadata] || %{},
      proficiency_levels: attrs[:proficiency_levels] || [],
      source_skill_id: attrs[:source_skill_id],
      embedding: attrs[:embedding],
      embedding_text_hash: attrs[:embedding_text_hash],
      embedded_at: attrs[:embedded_at],
      inserted_at: now,
      updated_at: now
    }
  end

  defp update_existing_skill(attrs, existing_by_slug) do
    slug = Skill.slugify(attrs[:name])
    existing_skill = Map.fetch!(existing_by_slug, slug)
    attrs = guard_status_downgrade(existing_skill, attrs)

    {:ok, skill} =
      existing_skill
      |> Skill.changeset(Map.drop(attrs, [:library_id, "library_id"]))
      |> Repo.update()

    skill
  end

  defp guard_status_downgrade(%Skill{status: "published"}, attrs) do
    Map.delete(attrs, :status) |> Map.delete("status")
  end

  defp guard_status_downgrade(_skill, attrs), do: attrs

  defp normalize_skill_attrs(skill_map) do
    %{
      category: skill_map[:category] || "",
      cluster: skill_map[:cluster] || "",
      name: skill_map[:skill_name] || skill_map[:name],
      description: skill_map[:skill_description] || skill_map[:description] || "",
      proficiency_levels: skill_map[:proficiency_levels] || [],
      status: "published"
    }
  end

  # --- Save to Library (structured skill maps) ---

  def save_to_library(library_id, skills) do
    do_save_to_library(library_id, skills)
  end

  def save_to_library(org_id, library_id, skills) do
    lib = get_library(org_id, library_id)

    cond do
      is_nil(lib) ->
        {:error, :not_found}

      Library.draft?(lib) ->
        do_save_to_library(library_id, skills)

      true ->
        # Published library — auto-create a draft and save there
        case create_draft_from_latest(org_id, lib.name) do
          {:ok, %{library: draft}} ->
            save_skills_to_draft(draft.id, skills)

          {:error, :draft_exists, _msg} ->
            draft = get_draft(org_id, lib.name)
            save_skills_to_draft(draft.id, skills)

          error ->
            error
        end
    end
  end

  defp save_skills_to_draft(draft_id, skills) do
    case do_save_to_library(draft_id, skills) do
      {:ok, result} -> {:ok, Map.put(result, :draft_library_id, draft_id)}
      error -> error
    end
  end

  defp do_save_to_library(library_id, skills) do
    normalized = Enum.map(skills, &normalize_skill_attrs/1)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:skills, fn _repo, _ ->
      bulk_upsert_skills(library_id, normalized)
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
    include_public = Keyword.get(opts, :include_public, true)
    pattern = "%#{sanitize_query(query)}%"

    base =
      from(s in Skill,
        join: l in Library,
        on: s.library_id == l.id,
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

    base
    |> scope_skills_to_visible_libraries(org_id, include_public)
    |> maybe_filter(:category, category)
    |> Repo.all()
  end

  defp scope_skills_to_visible_libraries(query, org_id, true) do
    from([_s, l] in query, where: l.organization_id == ^org_id or l.visibility == "public")
  end

  defp scope_skills_to_visible_libraries(query, org_id, false) do
    from([_s, l] in query, where: l.organization_id == ^org_id)
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

  defp copy_all_skills(source_id, draft_id) do
    pairs = list_skills(source_id) |> Enum.map(fn s -> {s, s.name} end)
    copy_skills_bulk(pairs, draft_id)
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

    existing = Repo.get_by(Skill, library_id: target_library_id, slug: slug)
    attrs = add_embedding_attrs_with_source(attrs, existing, skill)

    case existing do
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

  # Bulk copy: takes [{source_skill, target_name}] pairs (target_name may
  # differ from source.name when disambiguated by the merge flow). Pre-fetches
  # target slugs in a single query, batches embedding generation through one
  # `embed_many` call (reusing the source's embedding when its text hash
  # matches), then `insert_all`s the new rows. Existing rows in the target
  # library still go through per-row update via the shared helper.
  defp copy_skills_bulk([], _target_library_id), do: []

  defp copy_skills_bulk(pairs, target_library_id) do
    slugs = Enum.map(pairs, fn {_, name} -> Skill.slugify(name) end)

    existing =
      from(s in Skill, where: s.library_id == ^target_library_id and s.slug in ^slugs)
      |> Repo.all()
      |> Map.new(&{&1.slug, &1})

    attr_list = build_copy_attrs_bulk(pairs, existing)

    {to_insert, to_update} =
      Enum.split_with(attr_list, fn attrs ->
        is_nil(Map.get(existing, Skill.slugify(attrs[:name])))
      end)

    inserted = bulk_insert_new_skills(to_insert, target_library_id)
    updated = Enum.map(to_update, &update_existing_skill(&1, existing))

    inserted ++ updated
  end

  defp build_copy_attrs_bulk(pairs, existing) do
    prepared =
      Enum.map(pairs, fn {source_skill, target_name} ->
        attrs = base_copy_attrs(source_skill, target_name)
        slug = Skill.slugify(target_name)
        target_existing = Map.get(existing, slug)
        text = embed_text_for(attrs, target_existing)
        hash = text_hash(text)

        cond do
          target_existing && target_existing.embedding_text_hash == hash &&
              not is_nil(target_existing.embedding) ->
            {attrs, :reuse_target, nil, hash}

          source_skill.embedding_text_hash == hash and
              not is_nil(source_skill.embedding) ->
            {attrs, :reuse_source, source_skill.embedding, hash}

          true ->
            {attrs, :needs_embed, text, hash}
        end
      end)

    texts_to_embed =
      prepared
      |> Enum.filter(fn {_, tag, _, _} -> tag == :needs_embed end)
      |> Enum.map(fn {_, _, text_or_vec, _} -> text_or_vec end)
      |> Enum.uniq()

    vec_by_text =
      case rho_embed_many(texts_to_embed) do
        {:ok, vecs} -> texts_to_embed |> Enum.zip(vecs) |> Map.new()
        {:error, _} -> %{}
      end

    Enum.map(prepared, fn
      {attrs, :reuse_target, _, _} ->
        attrs

      {attrs, :reuse_source, vec, hash} ->
        put_embedding_fields(attrs, vec, hash)

      {attrs, :needs_embed, text, hash} ->
        case Map.get(vec_by_text, text) do
          nil -> attrs
          vec -> put_embedding_fields(attrs, vec, hash)
        end
    end)
  end

  defp base_copy_attrs(source_skill, target_name) do
    %{
      name: target_name,
      description: source_skill.description,
      category: source_skill.category,
      cluster: source_skill.cluster,
      status: source_skill.status,
      sort_order: source_skill.sort_order,
      metadata: source_skill.metadata,
      proficiency_levels: source_skill.proficiency_levels,
      source_skill_id: source_skill.id
    }
  end

  # --- Diff ---

  def diff_against_source(org_id, library_id) do
    lib = get_library!(org_id, library_id) |> Repo.preload(:derived_from)

    if lib.derived_from_id do
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
    else
      {:error, :no_source, "This library was not forked from another library."}
    end
  end

  defp skill_modified?(source, fork) do
    source.name != fork.name ||
      source.description != fork.description ||
      source.proficiency_levels != fork.proficiency_levels
  end

  # --- Combine Libraries ---

  @doc """
  Preview what combining source libraries would produce, without writing to DB.

  Returns `{:ok, preview}` where preview contains:
  - `:clean` — skills unique across sources (no conflicts)
  - `:conflicts` — duplicate pairs detected across source boundaries
  - `:sources` — source library summaries
  - `:stats` — `%{total: N, clean: N, conflicted: N}`
  """
  def combine_preview(org_id, source_library_ids) when is_list(source_library_ids) do
    sources =
      Enum.map(source_library_ids, fn id ->
        case get_library(org_id, id) do
          nil -> get_public_library!(id)
          lib -> lib
        end
      end)

    # Collect all skills tagged with their source library
    tagged_skills =
      Enum.flat_map(sources, fn src ->
        list_skills(src.id)
        |> Enum.map(fn skill -> {skill, src} end)
      end)

    # Build slug groups to find cross-source conflicts
    slug_groups =
      Enum.group_by(tagged_skills, fn {skill, _src} -> Skill.slugify(skill.name) end)

    # Skills with slug collisions across different sources are conflicts
    {clean_tagged, conflict_groups} =
      Enum.split_with(slug_groups, fn {_slug, group} ->
        source_ids = group |> Enum.map(fn {_s, src} -> src.id end) |> Enum.uniq()
        length(source_ids) <= 1 or length(group) <= 1
      end)

    clean =
      clean_tagged
      |> Enum.flat_map(fn {_slug, group} -> group end)
      |> Enum.map(fn {skill, src} ->
        %{
          skill_id: skill.id,
          name: skill.name,
          category: skill.category,
          source_library_id: src.id,
          source_library_name: src.name
        }
      end)

    # For conflict groups, also run word-overlap detection within each group
    slug_conflicts =
      Enum.flat_map(conflict_groups, fn {_slug, group} ->
        cross_source_pairs(group)
      end)

    # Additionally, run word-overlap across all source skills for non-slug matches
    all_skills = Enum.map(tagged_skills, fn {skill, src} -> {skill, src} end)
    word_conflicts = find_cross_source_word_overlaps(all_skills)

    # Merge and deduplicate conflict pairs
    all_conflicts =
      (slug_conflicts ++ word_conflicts)
      |> deduplicate_pairs()
      |> enrich_preview_conflicts()

    # Skills involved in conflicts
    conflicted_ids =
      all_conflicts
      |> Enum.flat_map(fn c -> [c.skill_a.id, c.skill_b.id] end)
      |> MapSet.new()

    # Remove conflicted skills from clean list
    clean = Enum.reject(clean, fn s -> MapSet.member?(conflicted_ids, s.skill_id) end)

    source_summaries =
      Enum.map(sources, fn src ->
        %{
          id: src.id,
          name: src.name,
          skill_count: Enum.count(tagged_skills, fn {_s, s} -> s.id == src.id end)
        }
      end)

    total = length(tagged_skills)

    {:ok,
     %{
       clean: clean,
       conflicts: all_conflicts,
       sources: source_summaries,
       stats: %{total: total, clean: length(clean), conflicted: length(all_conflicts)}
     }}
  end

  @doc """
  Commit a combined library with pre-resolved conflicts.

  `resolutions` is a list of maps:
    - `%{"skill_a_id" => id, "skill_b_id" => id, "action" => "merge", "keep" => id}`
    - `%{"skill_a_id" => id, "skill_b_id" => id, "action" => "keep_both"}`
    - `%{"skill_a_id" => id, "skill_b_id" => id, "action" => "pick", "keep" => id}`
  """
  def combine_commit(org_id, source_library_ids, new_name, resolutions, opts \\ [])
      when is_list(source_library_ids) do
    description = Keyword.get(opts, :description)

    sources =
      Enum.map(source_library_ids, fn id ->
        case get_library(org_id, id) do
          nil -> get_public_library!(id)
          lib -> lib
        end
      end)

    desc =
      description ||
        case sources do
          [single] -> "Derived from #{single.name}"
          many -> "Combined from: #{Enum.map_join(many, ", ", & &1.name)}"
        end

    # Build skip/merge/disambiguate sets from resolutions
    {skip_ids, merge_map, disambiguate_ids} = build_resolution_plan(resolutions)

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
      eligible_skills =
        sources
        |> Enum.flat_map(fn src -> list_skills(src.id) end)
        |> Enum.reject(&MapSet.member?(skip_ids, &1.id))

      # First pass: copy non-skipped skills. Skills in disambiguate_ids
      # (keep_both resolutions) get a "(N)" suffix on slug collision
      # instead of being deduped away.
      {copied, _seen} =
        copy_skills_with_targeted_disambiguation(eligible_skills, lib.id, disambiguate_ids)

      # Second pass: apply merge resolutions (absorb proficiency levels from dropped skill)
      copied_by_source = Map.new(copied, fn s -> {s.source_skill_id, s} end)

      apply_merge_resolutions(merge_map, copied_by_source)

      {:ok, Map.new(Enum.reverse(copied), &{&1.source_skill_id, &1})}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{library: lib, skills: skill_map}} ->
        {:ok, %{library: lib, skill_count: map_size(skill_map)}}

      error ->
        error
    end
  end

  # Build skip set and merge map from resolutions.
  # Accepts two formats:
  #   1. %{"skill_a_id" => id, "skill_b_id" => id, "action" => ..., "keep" => id}
  #   2. %{"conflict_id" => "id_a:id_b", "action" => ..., "keep_skill_id" => id}
  defp build_resolution_plan(resolutions) do
    resolutions
    |> Enum.map(&normalize_resolution/1)
    |> Enum.reduce({MapSet.new(), %{}, MapSet.new()}, &apply_resolution/2)
  end

  defp apply_resolution(res, {skip, merges, disambiguate}) do
    keep_id = res["keep"]
    a_id = res["skill_a_id"]
    b_id = res["skill_b_id"]

    case res["action"] do
      action when action in ["pick", "merge"] ->
        drop_id = if keep_id == a_id, do: b_id, else: a_id
        merges = if action == "merge", do: Map.put(merges, keep_id, drop_id), else: merges
        {MapSet.put(skip, drop_id), merges, disambiguate}

      "keep_both" when is_binary(a_id) and is_binary(b_id) ->
        # Both skills survive; whichever is iterated second hits a slug
        # collision and gets a "(N)" suffix in
        # copy_skills_with_targeted_disambiguation/3.
        {skip, merges, disambiguate |> MapSet.put(a_id) |> MapSet.put(b_id)}

      _ ->
        {skip, merges, disambiguate}
    end
  end

  # Normalize agent format (conflict_id + keep_skill_id) to canonical format
  defp normalize_resolution(%{"conflict_id" => conflict_id} = res) do
    case String.split(conflict_id, ":") do
      [a_id, b_id] ->
        %{
          "skill_a_id" => a_id,
          "skill_b_id" => b_id,
          "action" => res["action"],
          "keep" => res["keep_skill_id"] || res["keep"]
        }

      _ ->
        res
    end
  end

  defp normalize_resolution(res), do: res

  # Generate conflict pairs from skills that share a slug but come from different sources
  defp cross_source_pairs(tagged_group) do
    for {skill_a, src_a} <- tagged_group,
        {skill_b, src_b} <- tagged_group,
        skill_a.id < skill_b.id,
        src_a.id != src_b.id do
      %{
        skill_a: preview_skill_summary(skill_a, src_a),
        skill_b: preview_skill_summary(skill_b, src_b),
        confidence: :high,
        detection_method: :slug_prefix
      }
    end
  end

  # Find word-overlap duplicates across source boundaries (not caught by slug match)
  defp find_cross_source_word_overlaps(tagged_skills) do
    for {skill_a, src_a} <- tagged_skills,
        {skill_b, src_b} <- tagged_skills,
        skill_a.id < skill_b.id,
        src_a.id != src_b.id,
        Skill.slugify(skill_a.name) != Skill.slugify(skill_b.name),
        jaccard_similarity(skill_a.name, skill_b.name) >= 0.5 do
      %{
        skill_a: preview_skill_summary(skill_a, src_a),
        skill_b: preview_skill_summary(skill_b, src_b),
        confidence: :medium,
        detection_method: :word_overlap
      }
    end
  end

  defp preview_skill_summary(skill, source) do
    level_count =
      case skill.proficiency_levels do
        levels when is_list(levels) -> length(levels)
        _ -> 0
      end

    %{
      id: skill.id,
      name: skill.name,
      category: skill.category,
      description: skill.description,
      source_library_id: source.id,
      source_library_name: source.name,
      level_count: level_count
    }
  end

  defp enrich_preview_conflicts(conflicts) do
    skill_ids =
      Enum.flat_map(conflicts, fn c -> [c.skill_a.id, c.skill_b.id] end)
      |> Enum.uniq()

    role_counts =
      if skill_ids == [] do
        %{}
      else
        from(rs in RoleSkill,
          where: rs.skill_id in ^skill_ids,
          group_by: rs.skill_id,
          select: {rs.skill_id, count(rs.id)}
        )
        |> Repo.all()
        |> Map.new()
      end

    Enum.map(conflicts, fn c ->
      %{
        c
        | skill_a: Map.put(c.skill_a, :role_count, Map.get(role_counts, c.skill_a.id, 0)),
          skill_b: Map.put(c.skill_b, :role_count, Map.get(role_counts, c.skill_b.id, 0))
      }
    end)
  end

  def combine_libraries(org_id, source_library_ids, new_name, opts \\ [])
      when is_list(source_library_ids) do
    combine_commit(org_id, source_library_ids, new_name, [], opts)
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
    description = Keyword.get(opts, :description)

    sources =
      Enum.map(source_library_ids, fn id ->
        case get_library(org_id, id) do
          nil -> get_public_library!(id)
          lib -> lib
        end
      end)

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

      {copied, _seen} = copy_skills_with_disambiguation(all_skills, lib.id)

      {:ok, Map.new(Enum.reverse(copied), &{&1.source_skill_id, &1})}
    end)
    |> Repo.transaction()
  end

  # --- Import Library ---

  def import_library(org_id, skill_maps, opts \\ []) do
    name = Keyword.get(opts, :name, "Imported Library")
    description = Keyword.get(opts, :description)
    visibility = Keyword.get(opts, :visibility, "private")

    Ecto.Multi.new()
    |> Ecto.Multi.run(:library, fn _repo, _ ->
      create_library(org_id, %{name: name, description: description, visibility: visibility})
    end)
    |> Ecto.Multi.run(:skills, fn _repo, %{library: lib} ->
      normalized = Enum.map(skill_maps, &normalize_skill_attrs/1)
      bulk_upsert_skills(lib.id, normalized)
    end)
    |> Repo.transaction()
  end

  # --- Template Loading ---

  def load_template(org_id, source_key, template_data, opts \\ []) do
    visibility = Keyword.get(opts, :visibility, "private")

    Ecto.Multi.new()
    |> Ecto.Multi.run(:library, fn _repo, _ ->
      create_library(org_id, %{
        name: template_data.name,
        description: template_data[:description],
        immutable: true,
        source_key: source_key,
        visibility: visibility
      })
    end)
    |> Ecto.Multi.run(:skills, fn _repo, %{library: lib} ->
      normalized = Enum.map(template_data.skills, &normalize_skill_attrs/1)
      bulk_upsert_skills(lib.id, normalized, skip_mutability: true)
    end)
    |> Ecto.Multi.run(:role_profiles, fn _repo, %{library: lib, skills: skills} ->
      role_profile_defs = template_data[:role_profiles] || []
      {:ok, create_template_role_profiles(org_id, lib, role_profile_defs, skills)}
    end)
    |> Repo.transaction()
  end

  defp create_template_role_profiles(_org_id, _lib, [], _skills), do: []

  defp create_template_role_profiles(org_id, lib, role_profile_defs, skills) do
    skill_by_name = Map.new(skills, fn skill -> {skill.name, skill} end)
    Enum.map(role_profile_defs, &create_template_role_profile(org_id, lib, &1, skill_by_name))
  end

  defp create_template_role_profile(org_id, _library, rp_def, skill_by_name) do
    {:ok, rp} =
      %RoleProfile{}
      |> RoleProfile.changeset(%{
        name: rp_def[:name],
        role_family: rp_def[:role_family],
        seniority_level: rp_def[:seniority_level],
        seniority_label: rp_def[:seniority_label],
        purpose: rp_def[:purpose],
        immutable: true,
        organization_id: org_id
      })
      |> Repo.insert()

    skill_defs = rp_def[:skills] || []

    Enum.each(skill_defs, fn skill_def ->
      skill = Map.get(skill_by_name, skill_def[:skill_name])

      if skill do
        %RoleSkill{}
        |> RoleSkill.changeset(%{
          role_profile_id: rp.id,
          skill_id: skill.id,
          min_expected_level: skill_def[:min_expected_level] || 1,
          weight: 1.0,
          required: Map.get(skill_def, :required, true)
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
        candidates ++ find_semantic_duplicates_via_llm(library_id, skills)
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
        repoint_role_skills(clean, target_id)
        {:ok, length(clean)}
      end)
      |> Ecto.Multi.run(:conflicts, fn _repo, _ ->
        {:ok, resolve_conflicts(conflicted, target_ref_map, conflict_strategy)}
      end)
      |> Ecto.Multi.run(:levels, fn _repo, _ ->
        {:ok, merge_proficiency_levels(source, target)}
      end)
      |> Ecto.Multi.run(:rename, fn _repo, _ ->
        maybe_rename_skill(target, new_name)
      end)
      |> Ecto.Multi.run(:delete_source, fn _repo, _ ->
        # Delete orphaned source role_skills first
        from(rs in RoleSkill, where: rs.skill_id == ^source_id) |> Repo.delete_all()
        Repo.delete(source)
      end)
      |> Repo.transaction()
    end
  end

  defp apply_merge_resolutions(merge_map, copied_by_source) do
    Enum.each(merge_map, fn {keep_id, absorb_id} ->
      case {Map.get(copied_by_source, keep_id), Repo.get(Skill, absorb_id)} do
        {%Skill{} = target, %Skill{} = source} ->
          merge_proficiency_levels(source, target)

        _ ->
          :ok
      end
    end)
  end

  defp repoint_role_skills(role_skills, target_id) do
    Enum.each(role_skills, fn rs ->
      rs |> Ecto.Changeset.change(%{skill_id: target_id}) |> Repo.update!()
    end)
  end

  defp count_slug_variants(slugs, slug) do
    Enum.count(slugs, fn {k, _} -> String.starts_with?(k, slug <> "-") end)
  end

  # Copy skills with optional targeted disambiguation. Skills whose id
  # is in `disambiguate_ids` (keep_both resolutions) get a "(N)" suffix
  # on slug collision; all others fall back to slug-dedup (skip).
  # Equivalent to the deleted `copy_skills_deduped` when the set is
  # empty.
  defp copy_skills_with_targeted_disambiguation(skills, library_id, disambiguate_ids) do
    {pairs, _slugs} =
      Enum.reduce(skills, {[], %{}}, fn skill, {acc, slugs} ->
        slug = Skill.slugify(skill.name)

        case Map.get(slugs, slug) do
          nil ->
            {[{skill, skill.name} | acc], Map.put(slugs, slug, true)}

          _existing ->
            if MapSet.member?(disambiguate_ids, skill.id) do
              counter = count_slug_variants(slugs, slug) + 2
              disambiguated_name = "#{skill.name} (#{counter})"

              {[{skill, disambiguated_name} | acc],
               Map.put(slugs, Skill.slugify(disambiguated_name), true)}
            else
              {acc, slugs}
            end
        end
      end)

    copied = pairs |> Enum.reverse() |> copy_skills_bulk(library_id)
    {copied, %{}}
  end

  defp copy_skills_with_disambiguation(skills, library_id) do
    {pairs, _slugs} =
      Enum.reduce(skills, {[], %{}}, fn skill, {acc, slugs} ->
        slug = Skill.slugify(skill.name)

        case Map.get(slugs, slug) do
          nil ->
            {[{skill, skill.name} | acc], Map.put(slugs, slug, skill.description)}

          existing_desc when existing_desc == skill.description ->
            {acc, slugs}

          _different_desc ->
            counter = count_slug_variants(slugs, slug) + 2
            disambiguated_name = "#{skill.name} (#{counter})"

            {[{skill, disambiguated_name} | acc],
             Map.put(slugs, Skill.slugify(disambiguated_name), skill.description)}
        end
      end)

    copied = pairs |> Enum.reverse() |> copy_skills_bulk(library_id)
    {copied, %{}}
  end

  defp resolve_conflicts(conflicted, target_ref_map, strategy) do
    Enum.map(conflicted, fn source_rs ->
      target_rs = target_ref_map[source_rs.role_profile_id]
      resolve_conflict(source_rs, target_rs, strategy)
    end)
  end

  defp maybe_rename_skill(_skill, nil), do: {:ok, nil}

  defp maybe_rename_skill(skill, new_name) do
    skill |> Skill.changeset(%{name: new_name}) |> Repo.update()
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
  #
  # Two-stage funnel keeps cost flat as the library grows:
  #   1. Embedding pre-filter — pgvector cosine distance (`<=>`) finds pairs
  #      of skills whose embeddings cluster within
  #      @semantic_distance_threshold. Surfaces cross-name matches the jaro
  #      filter cannot catch ("数据分析" ↔ "Data Analysis"). Skills without
  #      embeddings (load failed, backfill not yet run) fall back to a
  #      jaro pairwise filter against the full skill list.
  #   2. LLM verification — chunked candidate pairs run in parallel; the
  #      model only sees plausible pairs and returns the indices that are
  #      TRUE duplicates. Token cost scales with candidate-pair count, not
  #      total skill count.

  # Cosine distance threshold (1 - cosine_similarity). 0.40 picked for
  # the post-LLM pipeline: dropping the LLM verifier means the cosine
  # filter alone is the signal, so we tighten the threshold so the
  # candidate set stays manageable for human review (~120 pairs at
  # 157 skills; ~600 at 0.50 was too noisy without LLM filtering).
  @semantic_distance_threshold 0.40

  # Confidence tiers for semantic pairs based on cosine distance.
  # Tighter distance ⇒ more likely a real duplicate.
  @semantic_high_distance_threshold 0.20
  @semantic_medium_distance_threshold 0.30

  # Soft cap on neighbors-per-skill returned by the HNSW KNN inner query.
  # Empirically the largest neighbor set we've seen per skill is ~30 at
  # 0.50; 200 is a generous ceiling. If a skill has >200 neighbors
  # within threshold, the tail gets dropped — accepted because the
  # tail is increasingly noisy and the LLM filter is the precision
  # gate.
  @semantic_knn_top_k 200

  @semantic_jaro_fallback_threshold 0.6

  # Embedding-only semantic dedup. Returns pairs with their cosine
  # distance attached so the UI / caller can rank candidates and apply
  # its own threshold per use case.
  #
  # An LLM verifier was tried (DeepSeek-V3, Gemini 2.5 Flash, Haiku 4.5,
  # GPT-4o-mini, gpt-oss-120b) and rejected: the FSFM eval found ~75%
  # false-positive rate on the LLM's "confirmed" pairs regardless of
  # prompt iteration. The cosine signal is cleaner — surface it as
  # candidates, let humans dismiss/merge via `dismiss_duplicate/3`.
  defp find_semantic_duplicates_via_llm(_library_id, skills) when length(skills) < 2, do: []

  defp find_semantic_duplicates_via_llm(library_id, skills) do
    embedding_pairs = candidate_pairs_via_embedding_with_distance(library_id)

    fallback_pairs =
      candidate_pairs_via_jaro_fallback(skills)
      # Jaro-only pairs don't have a meaningful cosine distance — tag
      # them with nil and bucket them as :low confidence.
      |> Enum.map(fn {a, b} -> {a, b, nil} end)

    (embedding_pairs ++ fallback_pairs)
    |> Enum.uniq_by(fn {a, b, _} -> sorted_pair_key(a.id, b.id) end)
    |> Enum.map(&build_semantic_pair_with_distance/1)
  end

  defp build_semantic_pair_with_distance({a, b, distance}) do
    {sa, sb} = if a.id < b.id, do: {a, b}, else: {b, a}

    %{
      skill_a: %{id: sa.id, name: sa.name, category: sa.category},
      skill_b: %{id: sb.id, name: sb.name, category: sb.category},
      cosine_distance: distance,
      confidence: confidence_from_distance(distance),
      detection_method: :semantic
    }
  end

  defp confidence_from_distance(nil), do: :low
  defp confidence_from_distance(d) when d < @semantic_high_distance_threshold, do: :high
  defp confidence_from_distance(d) when d < @semantic_medium_distance_threshold, do: :medium
  defp confidence_from_distance(_), do: :low

  defp sorted_pair_key(id_a, id_b) do
    if id_a < id_b, do: {id_a, id_b}, else: {id_b, id_a}
  end

  # Per-skill KNN via LATERAL join. The inner subquery's
  # `ORDER BY ... <=> ... LIMIT N` is exactly the shape pgvector's HNSW
  # index accelerates — drops a 6s pairwise scan to sub-second on real
  # libraries. Returns {skill_a, skill_b, cosine_distance} triples; the
  # full Skill rows are fetched in a single follow-up query and stitched
  # back together.
  defp candidate_pairs_via_embedding_with_distance(library_id) do
    threshold = @semantic_distance_threshold
    top_k = @semantic_knn_top_k

    sql = """
    SELECT s1.id AS a_id, s2.id AS b_id, s2.dist AS dist
    FROM skills s1
    CROSS JOIN LATERAL (
      SELECT s.id, (s.embedding <=> s1.embedding) AS dist
      FROM skills s
      WHERE s.library_id = s1.library_id
        AND s.id > s1.id
        AND s.embedding IS NOT NULL
        AND (s.embedding <=> s1.embedding) < $2
      ORDER BY s.embedding <=> s1.embedding
      LIMIT $3
    ) s2
    WHERE s1.library_id = $1
      AND s1.embedding IS NOT NULL
    """

    %{rows: rows} =
      Repo.query!(sql, [Ecto.UUID.dump!(library_id), threshold, top_k],
        timeout: :timer.minutes(2)
      )

    case rows do
      [] ->
        []

      _ ->
        triples =
          Enum.map(rows, fn [a_uuid, b_uuid, dist] ->
            {Ecto.UUID.cast!(a_uuid), Ecto.UUID.cast!(b_uuid), dist}
          end)

        ids =
          triples
          |> Enum.flat_map(fn {a, b, _} -> [a, b] end)
          |> Enum.uniq()

        skills_by_id =
          from(s in Skill, where: s.id in ^ids)
          |> Repo.all()
          |> Map.new(&{&1.id, &1})

        Enum.map(triples, fn {a_id, b_id, dist} ->
          {Map.fetch!(skills_by_id, a_id), Map.fetch!(skills_by_id, b_id), dist}
        end)
    end
  end

  # Jaro fallback for skills missing embeddings — pairs each non-embedded
  # skill against the full library list so a non-embedded row can still
  # pair with an embedded one. Runs in-memory; cheap O(n) per non-embedded
  # skill.
  defp candidate_pairs_via_jaro_fallback(skills) do
    {without_embedding, _with_embedding} =
      Enum.split_with(skills, fn s -> is_nil(s.embedding) end)

    case without_embedding do
      [] ->
        []

      _ ->
        threshold = @semantic_jaro_fallback_threshold

        for a <- without_embedding,
            b <- skills,
            a.id != b.id,
            String.jaro_distance(String.downcase(a.name), String.downcase(b.name)) >= threshold do
          if a.id < b.id, do: {a, b}, else: {b, a}
        end
    end
  end

  # --- Embedding helpers ---
  #
  # Embeddings are computed inline on upsert so dedup pre-filtering can run
  # against pgvector's `<=>` operator. The text is `name\ndescription`,
  # SHA-256 hashed for change detection — re-embedding only happens when the
  # hash differs (or when no embedding has ever been written).
  #
  # If RhoEmbeddings returns `{:error, :not_ready | :disabled | _}`, we log
  # and save the row WITHOUT an embedding. The `BackfillEmbeddings` mix
  # task picks these up later.

  defp add_embedding_attrs(attrs, existing) do
    text = embed_text_for(attrs, existing)
    hash = text_hash(text)

    cond do
      existing && existing.embedding_text_hash == hash && not is_nil(existing.embedding) ->
        attrs

      true ->
        case rho_embed_one(text) do
          {:ok, vec} -> put_embedding_fields(attrs, vec, hash)
          {:error, _} -> attrs
        end
    end
  end

  # Like add_embedding_attrs/2 but, on a fresh copy whose source row already
  # has an embedding for the exact same text, copies that embedding instead
  # of calling embed_many. Cheaper than re-embedding for fork/derive paths.
  defp add_embedding_attrs_with_source(attrs, existing, source_skill) do
    text = embed_text_for(attrs, existing)
    hash = text_hash(text)

    cond do
      existing && existing.embedding_text_hash == hash && not is_nil(existing.embedding) ->
        attrs

      source_skill && source_skill.embedding_text_hash == hash &&
          not is_nil(source_skill.embedding) ->
        put_embedding_fields(attrs, source_skill.embedding, hash)

      true ->
        case rho_embed_one(text) do
          {:ok, vec} -> put_embedding_fields(attrs, vec, hash)
          {:error, _} -> attrs
        end
    end
  end

  # Bulk path: build texts that need embedding for the whole batch, run a
  # single embed_many call, then merge results back per-attrs. No-op for
  # rows where the existing hash already matches the new text.
  defp add_embedding_attrs_bulk(attr_list, existing_by_slug) do
    prepared =
      Enum.map(attr_list, fn attrs ->
        slug = Skill.slugify(attrs[:name])
        existing = Map.get(existing_by_slug, slug)
        text = embed_text_for(attrs, existing)
        hash = text_hash(text)

        needs_embed? =
          is_nil(existing) or existing.embedding_text_hash != hash or
            is_nil(existing.embedding)

        {attrs, text, hash, needs_embed?}
      end)

    texts_to_embed =
      prepared
      |> Enum.filter(fn {_a, _t, _h, needs?} -> needs? end)
      |> Enum.map(fn {_a, t, _h, _n} -> t end)
      |> Enum.uniq()

    vec_by_text =
      case rho_embed_many(texts_to_embed) do
        {:ok, vecs} -> texts_to_embed |> Enum.zip(vecs) |> Map.new()
        {:error, _} -> %{}
      end

    Enum.map(prepared, fn {attrs, text, hash, needs_embed?} ->
      case needs_embed? && Map.get(vec_by_text, text) do
        false -> attrs
        nil -> attrs
        vec -> put_embedding_fields(attrs, vec, hash)
      end
    end)
  end

  defp put_embedding_fields(attrs, vec, hash) do
    Map.merge(attrs, %{
      embedding: vec,
      embedding_text_hash: hash,
      embedded_at: DateTime.utc_now()
    })
  end

  defp embed_text_for(attrs, existing) do
    name = attrs[:name] || (existing && existing.name) || ""

    desc =
      cond do
        Map.has_key?(attrs, :description) -> attrs[:description] || ""
        Map.has_key?(attrs, "description") -> attrs["description"] || ""
        existing -> existing.description || ""
        true -> ""
      end

    "#{name}\n#{desc}"
  end

  defp text_hash(text), do: :crypto.hash(:sha256, text)

  defp rho_embed_one(text) do
    case rho_embed_many([text]) do
      {:ok, [vec]} -> {:ok, vec}
      other -> other
    end
  end

  defp rho_embed_many([]), do: {:ok, []}

  defp rho_embed_many(texts) do
    case RhoEmbeddings.embed_many(texts) do
      {:ok, vecs} ->
        {:ok, vecs}

      {:error, reason} = err ->
        Logger.warning(
          "RhoEmbeddings.embed_many failed (#{inspect(reason)}); saving skills without embeddings"
        )

        err
    end
  catch
    :exit, reason ->
      Logger.warning(
        "RhoEmbeddings.Server unavailable (#{inspect(reason)}); saving skills without embeddings"
      )

      {:error, :not_running}
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

    Enum.map(candidates, &enrich_candidate(&1, role_refs))
  end

  defp enrich_candidate(c, role_refs) do
    refs_a = Map.get(role_refs, c.skill_a.id, [])
    refs_b = Map.get(role_refs, c.skill_b.id, [])

    role_names_a = Enum.map(refs_a, &elem(&1, 0))
    role_names_b = Enum.map(refs_b, &elem(&1, 0))

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
    # Show drafts + latest published per name (no superseded versions)
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

  defp skills_filter_opts(:all), do: []
  defp skills_filter_opts(categories) when is_list(categories), do: [categories: categories]
  defp skills_filter_opts(_), do: []

  defp sanitize_query(query) do
    query
    |> String.replace(~r/[^\w\s]/, "")
    |> String.trim()
  end
end
