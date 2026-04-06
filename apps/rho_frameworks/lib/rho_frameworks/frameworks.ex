defmodule RhoFrameworks.Frameworks do
  @moduledoc "Context for skill framework persistence, search, and analysis."

  import Ecto.Query
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Frameworks.{Framework, Skill}

  ## Framework CRUD (all scoped by user_id)

  def list_frameworks(user_id) do
    skill_counts =
      from(s in Skill,
        group_by: s.framework_id,
        select: {s.framework_id, count()}
      )
      |> Repo.all()
      |> Map.new()

    frameworks =
      from(f in Framework,
        where: f.user_id == ^user_id,
        order_by: [desc: f.updated_at]
      )
      |> Repo.all()

    Enum.map(frameworks, fn f ->
      %{
        id: f.id,
        name: f.name,
        description: f.description,
        metadata: f.metadata,
        updated_at: f.updated_at,
        skill_count: Map.get(skill_counts, f.id, 0)
      }
    end)
  end

  def get_framework(user_id, name) when is_binary(name) do
    Repo.get_by(Framework, user_id: user_id, name: name)
  end

  def get_framework!(user_id, id) do
    Repo.get_by!(Framework, id: id, user_id: user_id)
  end

  def get_framework_with_skills(user_id, name) when is_binary(name) do
    case get_framework(user_id, name) do
      nil -> nil
      framework -> Repo.preload(framework, skills: from(s in Skill, order_by: s.sort_order))
    end
  end

  def get_framework_with_skills!(user_id, id) do
    get_framework!(user_id, id)
    |> Repo.preload(skills: from(s in Skill, order_by: s.sort_order))
  end

  def save_framework(user_id, name, description, rows, opts \\ []) do
    overwrite = Keyword.get(opts, :overwrite, false)
    metadata = Keyword.get(opts, :metadata, %{})

    Ecto.Multi.new()
    |> Ecto.Multi.run(:framework, fn repo, _changes ->
      case repo.get_by(Framework, user_id: user_id, name: name) do
        nil ->
          %Framework{}
          |> Framework.changeset(%{
            user_id: user_id,
            name: name,
            description: description,
            metadata: metadata
          })
          |> repo.insert()

        existing when overwrite ->
          # Delete old skills, update framework
          from(s in Skill, where: s.framework_id == ^existing.id) |> repo.delete_all()

          existing
          |> Framework.changeset(%{description: description, metadata: metadata})
          |> repo.update()

        _existing ->
          {:error, :name_taken}
      end
    end)
    |> Ecto.Multi.run(:skills, fn repo, %{framework: framework} ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      skill_entries =
        rows
        |> Enum.with_index()
        |> Enum.map(fn {row, idx} ->
          %{
            id: Ecto.UUID.generate(),
            framework_id: framework.id,
            category: row[:category] || row["category"] || "",
            cluster: row[:cluster] || row["cluster"] || "",
            skill_name: row[:skill_name] || row["skill_name"] || "",
            skill_description: row[:skill_description] || row["skill_description"] || "",
            level: row[:level] || row["level"] || 0,
            level_name: row[:level_name] || row["level_name"] || "",
            level_description: row[:level_description] || row["level_description"] || "",
            sort_order: idx,
            inserted_at: now,
            updated_at: now
          }
        end)

      # Bulk insert in chunks to stay within SQLite variable limits
      skill_entries
      |> Enum.chunk_every(100)
      |> Enum.each(fn chunk ->
        repo.insert_all(Skill, chunk)
      end)

      {:ok, length(skill_entries)}
    end)
    |> Repo.transaction()
  end

  def delete_framework(user_id, name) when is_binary(name) do
    case get_framework(user_id, name) do
      nil -> {:error, :not_found}
      framework -> Repo.delete(framework)
    end
  end

  ## Search (FTS5)

  def search_skills(user_id, query, opts \\ []) do
    framework_name = Keyword.get(opts, :framework_name)
    category = Keyword.get(opts, :category)
    limit = Keyword.get(opts, :limit, 50)

    # Sanitize FTS query: escape special characters
    safe_query = sanitize_fts_query(query)

    base =
      from(s in Skill,
        join: f in Framework,
        on: s.framework_id == f.id,
        where: f.user_id == ^user_id,
        select: %{
          framework_name: f.name,
          category: s.category,
          cluster: s.cluster,
          skill_name: s.skill_name,
          skill_description: s.skill_description,
          level: s.level,
          level_name: s.level_name,
          level_description: s.level_description
        },
        limit: ^limit
      )

    base =
      if framework_name do
        from([s, f] in base, where: f.name == ^framework_name)
      else
        base
      end

    base =
      if category do
        from([s, f] in base, where: s.category == ^category)
      else
        base
      end

    # Use LIKE-based search as fallback (FTS5 requires raw SQL)
    pattern = "%#{safe_query}%"

    from([s, f] in base,
      where:
        like(s.skill_name, ^pattern) or
          like(s.skill_description, ^pattern) or
          like(s.category, ^pattern) or
          like(s.cluster, ^pattern) or
          like(s.level_description, ^pattern)
    )
    |> Repo.all()
  end

  ## Cross-reference

  def compare_frameworks(user_id, framework_names) when is_list(framework_names) do
    frameworks =
      from(f in Framework,
        where: f.user_id == ^user_id and f.name in ^framework_names,
        preload: [skills: ^from(s in Skill, order_by: s.sort_order)]
      )
      |> Repo.all()

    # Build skill sets per framework (by normalized skill_name)
    skill_sets =
      Map.new(frameworks, fn f ->
        skills =
          f.skills
          |> Enum.map(& &1.skill_name)
          |> Enum.uniq()
          |> MapSet.new()

        {f.name, skills}
      end)

    all_skills =
      skill_sets
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    shared =
      skill_sets
      |> Map.values()
      |> Enum.reduce(fn set, acc -> MapSet.intersection(acc, set) end)

    unique_per_framework =
      Map.new(skill_sets, fn {name, skills} ->
        others =
          skill_sets
          |> Map.delete(name)
          |> Map.values()
          |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        {name, MapSet.difference(skills, others) |> MapSet.to_list()}
      end)

    %{
      frameworks: Map.keys(skill_sets),
      total_unique_skills: MapSet.size(all_skills),
      shared_skills: MapSet.to_list(shared),
      shared_count: MapSet.size(shared),
      unique_per_framework: unique_per_framework
    }
  end

  ## Deduplication

  def find_duplicates(user_id, opts \\ []) do
    framework_name = Keyword.get(opts, :framework_name)

    base =
      from(s in Skill,
        join: f in Framework,
        on: s.framework_id == f.id,
        where: f.user_id == ^user_id
      )

    base =
      if framework_name do
        from([s, f] in base, where: f.name == ^framework_name)
      else
        base
      end

    # Group by normalized skill_name + category
    from([s, f] in base,
      group_by: [fragment("lower(trim(?))", s.skill_name), s.category],
      having: count() > 1,
      select: %{
        skill_name: fragment("lower(trim(?))", s.skill_name),
        category: s.category,
        count: count(),
        framework_names: fragment("group_concat(DISTINCT ?)", f.name)
      }
    )
    |> Repo.all()
  end

  ## Helpers

  defp sanitize_fts_query(query) do
    query
    |> String.replace(~r/[^\w\s]/, "")
    |> String.trim()
  end
end
