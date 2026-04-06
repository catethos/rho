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

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      row_maps =
        Enum.map(attrs.rows, fn row ->
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
      |> Enum.each(fn chunk ->
        Repo.insert_all(FrameworkRow, chunk)
      end)

      # Update cached counts — use change/2, not cast/4 (internal computed data)
      row_count = length(row_maps)
      skill_count = row_maps |> Enum.map(& &1.skill_name) |> Enum.uniq() |> length()

      framework
      |> Ecto.Changeset.change(%{row_count: row_count, skill_count: skill_count})
      |> Repo.update!()
    end)
  end

  # --- Helpers ---

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
