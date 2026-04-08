defmodule Rho.SkillStore do
  alias Rho.SkillStore.{Repo, Framework, FrameworkRow, Company}
  import Ecto.Query

  # --- Companies ---

  def ensure_company(company_id) do
    %Company{}
    |> Company.changeset(%{id: company_id, name: company_id})
    |> Repo.insert(on_conflict: :nothing)
  end

  # --- Frameworks ---

  def list_frameworks_for(company_id, is_admin, type_filter \\ nil) do
    query = from(f in Framework)

    query =
      if is_admin do
        query
      else
        where(query, [f], f.type == "industry" or f.company_id == ^(company_id || ""))
      end

    query =
      if type_filter do
        where(query, [f], f.type == ^type_filter)
      else
        query
      end

    query = order_by(query, [f], asc: f.type, asc: f.name)

    frameworks = Repo.all(query)
    framework_ids = Enum.map(frameworks, & &1.id)

    # Single query for ALL roles across all frameworks (no N+1)
    roles_by_framework =
      if framework_ids != [] do
        from(r in FrameworkRow,
          where: r.framework_id in ^framework_ids and r.role != "" and not is_nil(r.role),
          group_by: [r.framework_id, r.role],
          select: {r.framework_id, r.role},
          order_by: [r.framework_id, r.role]
        )
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      else
        %{}
      end

    Enum.map(frameworks, fn f ->
      Map.from_struct(f)
      |> Map.drop([:__meta__, :rows, :company])
      |> Map.put(:roles, Map.get(roles_by_framework, f.id, []))
    end)
  end

  def get_framework(id), do: Repo.get(Framework, id)

  # --- Framework Rows ---

  def get_framework_rows(framework_id) do
    from(r in FrameworkRow,
      where: r.framework_id == ^framework_id,
      order_by: r.id
    )
    |> Repo.all()
    |> Enum.map(&row_to_map/1)
  end

  def get_framework_role_directory(framework_id) do
    role_stats =
      from(r in FrameworkRow,
        where: r.framework_id == ^framework_id and r.role != "" and not is_nil(r.role),
        group_by: r.role,
        select: {r.role, count(fragment("DISTINCT ?", r.skill_name))},
        order_by: r.role
      )
      |> Repo.all()

    if role_stats == [] do
      []
    else
      role_names = Enum.map(role_stats, &elem(&1, 0))

      skills_by_role =
        from(r in FrameworkRow,
          where: r.framework_id == ^framework_id and r.role in ^role_names,
          select: {r.role, r.skill_name},
          order_by: [r.role, r.category, r.skill_name]
        )
        |> Repo.all()
        |> Enum.uniq_by(fn {role, skill} -> {role, skill} end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      Enum.map(role_stats, fn {role, skill_count} ->
        top_skills =
          skills_by_role
          |> Map.get(role, [])
          |> Enum.take(5)

        %{role: role, skill_count: skill_count, top_skills: top_skills}
      end)
    end
  end

  def get_framework_rows_for_roles(framework_id, role_names) when is_list(role_names) do
    from(r in FrameworkRow,
      where: r.framework_id == ^framework_id and r.role in ^role_names,
      order_by: r.id
    )
    |> Repo.all()
    |> Enum.map(&row_to_map/1)
  end

  # --- Save ---

  def save_framework(attrs) do
    Repo.transaction(fn ->
      framework =
        case attrs[:id] do
          nil ->
            %Framework{}
            |> Framework.changeset(%{
              name: attrs.name,
              type: attrs.type,
              company_id: attrs.company_id,
              source: attrs[:source]
            })
            |> Repo.insert!()

          id ->
            framework = Repo.get!(Framework, id)
            Repo.delete_all(from(r in FrameworkRow, where: r.framework_id == ^id))

            framework
            |> Framework.changeset(%{name: attrs.name, source: attrs[:source]})
            |> Repo.update!()
        end

      row_maps = insert_rows(framework, attrs.rows)
      update_counts(framework, row_maps)
    end)
  end

  def save_role_framework(attrs) do
    role_name = title_case(attrs.role_name || "")
    company_id = attrs.company_id
    year = attrs.year
    action = attrs.action

    case action do
      :create ->
        next_version =
          from(f in Framework,
            where:
              f.company_id == ^company_id and f.role_name == ^role_name and
                f.year == ^year and f.type == "company",
            select: max(f.version)
          )
          |> Repo.one()
          |> case do
            nil -> 1
            max_v -> max_v + 1
          end

        is_first =
          from(f in Framework,
            where:
              f.company_id == ^company_id and f.role_name == ^role_name and
                f.type == "company",
            select: count(f.id)
          )
          |> Repo.one() == 0

        name = generate_name(role_name, year, next_version)

        Repo.transaction(fn ->
          framework =
            %Framework{}
            |> Framework.changeset(%{
              name: name,
              type: "company",
              company_id: company_id,
              source: attrs[:source],
              role_name: role_name,
              year: year,
              version: next_version,
              is_default: is_first,
              description: attrs[:description] || ""
            })
            |> Repo.insert!()

          insert_rows(framework, attrs.rows)
          update_counts(framework, attrs.rows)
        end)

      :update ->
        existing_id = attrs.existing_id

        Repo.transaction(fn ->
          framework = Repo.get!(Framework, existing_id)
          Repo.delete_all(from(r in FrameworkRow, where: r.framework_id == ^existing_id))

          framework
          |> Framework.changeset(%{
            source: attrs[:source],
            description: attrs[:description] || framework.description
          })
          |> Repo.update!()

          insert_rows(framework, attrs.rows)
          update_counts(framework, attrs.rows)
        end)
    end
  end

  def get_company_roles_summary(company_id) do
    frameworks =
      from(f in Framework,
        where: f.company_id == ^company_id and f.type == "company" and not is_nil(f.role_name),
        order_by: [asc: f.role_name, desc: f.year, desc: f.version]
      )
      |> Repo.all()

    frameworks
    |> Enum.group_by(& &1.role_name)
    |> Enum.map(fn {role_name, versions} ->
      default = Enum.find(versions, hd(versions), & &1.is_default)

      %{
        role_name: role_name,
        default: %{
          id: default.id,
          year: default.year,
          version: default.version,
          skill_count: default.skill_count,
          row_count: default.row_count,
          description: default.description,
          inserted_at: default.inserted_at
        },
        versions:
          Enum.map(versions, fn v ->
            %{
              id: v.id,
              year: v.year,
              version: v.version,
              is_default: v.is_default,
              skill_count: v.skill_count,
              inserted_at: v.inserted_at
            }
          end)
      }
    end)
    |> Enum.sort_by(& &1.role_name)
  end

  def set_default_version(framework_id) do
    framework = Repo.get!(Framework, framework_id)

    Repo.transaction(fn ->
      from(f in Framework,
        where:
          f.company_id == ^framework.company_id and
            f.role_name == ^framework.role_name and
            f.is_default == true
      )
      |> Repo.update_all(set: [is_default: false])

      framework
      |> Ecto.Changeset.change(%{is_default: true})
      |> Repo.update!()
    end)
  end

  # --- Helpers ---

  defp insert_rows(framework, rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    row_maps =
      Enum.map(rows, fn row ->
        %{
          framework_id: framework.id,
          role: row[:role] || row["role"] || "",
          category: row[:category] || row["category"] || "",
          cluster: row[:cluster] || row["cluster"] || "",
          skill_name: row[:skill_name] || row["skill_name"] || "",
          skill_description: row[:skill_description] || row["skill_description"] || "",
          level: row[:level] || row["level"] || 0,
          level_name: row[:level_name] || row["level_name"] || "",
          level_description: row[:level_description] || row["level_description"] || "",
          skill_code: row[:skill_code] || row["skill_code"] || "",
          inserted_at: now,
          updated_at: now
        }
      end)

    row_maps
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk -> Repo.insert_all(FrameworkRow, chunk) end)

    row_maps
  end

  defp update_counts(framework, row_maps) when is_list(row_maps) do
    row_count = length(row_maps)
    skill_names = Enum.map(row_maps, fn r -> r[:skill_name] || r["skill_name"] || "" end)
    skill_count = skill_names |> Enum.uniq() |> length()

    framework
    |> Ecto.Changeset.change(%{row_count: row_count, skill_count: skill_count})
    |> Repo.update!()
  end

  defp generate_name(role_name, year, version) do
    slug =
      role_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    "#{slug}_#{year}_v#{version}"
  end

  defp title_case(str) do
    str
    |> String.split(~r/[\s_]+/)
    |> Enum.map(fn word ->
      case String.downcase(word) do
        "" -> ""
        w -> String.upcase(String.first(w)) <> String.slice(w, 1..-1//1)
      end
    end)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp row_to_map(%FrameworkRow{} = row) do
    %{
      role: row.role,
      category: row.category,
      cluster: row.cluster,
      skill_name: row.skill_name,
      skill_description: row.skill_description,
      level: row.level,
      level_name: row.level_name,
      level_description: row.level_description,
      skill_code: row.skill_code
    }
  end
end
