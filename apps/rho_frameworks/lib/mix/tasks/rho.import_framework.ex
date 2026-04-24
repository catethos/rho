defmodule Mix.Tasks.Rho.ImportFramework do
  use Mix.Task

  @shortdoc "Import a skills framework from an XLSX file into the database"

  @moduledoc """
  Import a skills framework from an XLSX file into the `rho_frameworks` database.

  Designed for the **Future Skills Framework for the Malaysian Financial Sector**
  XLSX format, which contains four sheets:

  | Sheet | Index | Content                        | Used by         |
  |-------|-------|--------------------------------|-----------------|
  | 0     | —     | Instructions / README          | Skipped         |
  | 1     | 1     | Job Roles & Descriptions       | `parse_roles/1` |
  | 2     | 2     | Skills → Job Roles Mapping     | `parse_skills/1`, `parse_mapping/1` |
  | 3     | 3     | Job Roles → Skills (transpose) | Not used (redundant with Sheet 2) |

  ## Data mapping

  | XLSX concept        | DB table         | Key fields                                          |
  |---------------------|------------------|-----------------------------------------------------|
  | Whole framework     | `libraries`      | name, type: "skill"                                 |
  | 157 skills          | `skills`         | category, cluster, name, description, proficiency_levels (5 PL maps) |
  | 161 job roles       | `role_profiles`  | name, role_family (cluster), purpose, description, metadata.sub_sectors |
  | Skill ↔ Role Y/N    | `role_skills`    | role_profile_id, skill_id, min_expected_level: 1    |

  Sub-sector applicability flags from Sheet 1 (columns 7–13) are stored in
  `role_profiles.metadata["sub_sectors"]` as a list of applicable sub-sector names.

  ## Usage

      # Import using default user (cloverethos@gmail.com) and library name
      mix rho.import_framework data.xlsx

      # Specify a different user's personal org
      mix rho.import_framework data.xlsx --email other@example.com

      # Override library name
      mix rho.import_framework data.xlsx --name "My Custom Framework"

      # Preview without writing to DB
      mix rho.import_framework data.xlsx --dry-run

  ## Idempotency

  The task is idempotent — re-running upserts skills (by slug) and role profiles
  (by name), and skips existing role-skill mappings. The library is created once
  and reused on subsequent runs.

  ## Known limitations

  - 11 role names in the Sheet 2 header are truncated or differ slightly from
    Sheet 1 names (e.g., "Shared Services and..." cut off). These roles are
    created but their skill mappings are not linked. Warnings are printed.
  - `min_expected_level` defaults to 1 for all role-skill mappings since the
    XLSX only contains Y/N (not proficiency-level requirements per role).
  """

  @sub_sector_columns [
    "Retail Banking and Islamic Retail Banking",
    "Corporate and Commercial Banking and Islamic Corporate and Commercial Banking",
    "Investment Banking and Islamic Investment Banking",
    "Development Financial Institutions",
    "Digital Banking and Islamic Digital Banking",
    "Insurance and Takaful",
    "Digital Insurance and Takaful"
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [email: :string, name: :string, org: :string, dry_run: :boolean, public: :boolean]
      )

    file = List.first(rest)

    unless file && File.exists?(file) do
      Mix.shell().error("Usage: mix rho.import_framework <file.xlsx> --email user@example.com")
      exit({:shutdown, 1})
    end

    email = opts[:email] || "cloverethos@gmail.com"
    org_name = opts[:org]
    lib_name = opts[:name] || "Future Skills Framework - Malaysian Financial Sector"
    dry_run = opts[:dry_run] || false
    visibility = if opts[:public], do: "public", else: "private"

    Application.ensure_all_started(:xlsxir)
    Mix.Task.run("app.start", ["--no-start"])
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = RhoFrameworks.Repo.start_link([])

    import Ecto.Query

    alias RhoFrameworks.Repo
    alias RhoFrameworks.Frameworks.{Library, Skill, RoleProfile, RoleSkill}

    # 1. Resolve user and org (auto-create if missing)
    user =
      case Repo.get_by(RhoFrameworks.Accounts.User, email: email) do
        nil ->
          Mix.shell().info("User #{email} not found, creating...")

          {:ok, user} =
            RhoFrameworks.Accounts.register_user(%{email: email, password: "password123456"})

          user

        user ->
          user
      end

    org =
      if org_name do
        Repo.one!(
          from(m in RhoFrameworks.Accounts.Membership,
            join: o in RhoFrameworks.Accounts.Organization,
            on: o.id == m.organization_id,
            where: m.user_id == ^user.id and o.name == ^org_name,
            select: o
          )
        )
      else
        Repo.one!(
          from(m in RhoFrameworks.Accounts.Membership,
            join: o in RhoFrameworks.Accounts.Organization,
            on: o.id == m.organization_id,
            where: m.user_id == ^user.id and o.personal == true,
            select: o
          )
        )
      end

    Mix.shell().info("User: #{user.email} | Org: #{org.name} (#{org.id})")

    # 2. Parse XLSX sheets
    skills_data = parse_skills(file)
    roles_data = parse_roles(file)
    mapping_data = parse_mapping(file)

    Mix.shell().info(
      "Parsed: #{length(skills_data)} skills, #{length(roles_data)} roles, #{length(mapping_data)} mappings"
    )

    if dry_run do
      Mix.shell().info("[DRY RUN] Would import above. Exiting.")
      exit(:normal)
    end

    # 3. Insert everything in a transaction
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:library, fn _repo, _ ->
        case Repo.get_by(Library, organization_id: org.id, name: lib_name) do
          nil ->
            %Library{}
            |> Library.changeset(%{
              name: lib_name,
              description:
                "Future Skills Framework for the Malaysian Financial Sector — imported from XLSX",
              type: "skill",
              visibility: visibility,
              organization_id: org.id
            })
            |> Repo.insert()

          existing ->
            existing
            |> Library.changeset(%{visibility: visibility})
            |> Repo.update()
        end
      end)
      |> Ecto.Multi.run(:skills, fn _repo, %{library: library} ->
        results =
          Enum.with_index(skills_data, 1)
          |> Enum.map(fn {skill_attrs, idx} ->
            attrs = Map.put(skill_attrs, :library_id, library.id) |> Map.put(:sort_order, idx)

            case Repo.get_by(Skill, library_id: library.id, slug: Skill.slugify(attrs[:name])) do
              nil ->
                %Skill{}
                |> Skill.changeset(attrs)
                |> Repo.insert!()

              existing ->
                existing
                |> Skill.changeset(Map.drop(attrs, [:library_id]))
                |> Repo.update!()
            end
          end)

        {:ok, results}
      end)
      |> Ecto.Multi.run(:role_profiles, fn _repo, %{library: _library} ->
        results =
          Enum.map(roles_data, fn role_attrs ->
            case Repo.get_by(RoleProfile, organization_id: org.id, name: role_attrs[:name]) do
              nil ->
                %RoleProfile{}
                |> RoleProfile.changeset(
                  Map.merge(role_attrs, %{
                    organization_id: org.id,
                    created_by_id: user.id
                  })
                )
                |> Repo.insert!()

              existing ->
                existing
                |> RoleProfile.changeset(Map.drop(role_attrs, [:organization_id]))
                |> Repo.update!()
            end
          end)

        {:ok, results}
      end)
      |> Ecto.Multi.run(:role_skills, fn _repo, %{skills: skills, role_profiles: rps} ->
        skill_by_name =
          Map.new(skills, fn s -> {normalize_name(s.name), s} end)

        rp_by_name =
          Map.new(rps, fn rp -> {normalize_name(rp.name), rp} end)

        results =
          Enum.flat_map(mapping_data, fn {role_name, skill_names} ->
            rp_key = normalize_name(role_name)

            rp = Map.get(rp_by_name, rp_key) || fuzzy_match(rp_key, rp_by_name, role_name)

            case rp do
              nil ->
                Mix.shell().info("  WARN: role '#{role_name}' not found, skipping mappings")
                []

              rp ->
                Enum.flat_map(skill_names, fn skill_name ->
                  sk_key = normalize_name(skill_name)

                  case Map.get(skill_by_name, sk_key) do
                    nil ->
                      Mix.shell().info(
                        "  WARN: skill '#{skill_name}' not found for role '#{role_name}'"
                      )

                      []

                    skill ->
                      case Repo.get_by(RoleSkill,
                             role_profile_id: rp.id,
                             skill_id: skill.id
                           ) do
                        nil ->
                          rs =
                            %RoleSkill{}
                            |> RoleSkill.changeset(%{
                              role_profile_id: rp.id,
                              skill_id: skill.id,
                              min_expected_level: 1,
                              weight: 1.0,
                              required: true
                            })
                            |> Repo.insert!()

                          [rs]

                        existing ->
                          [existing]
                      end
                  end
                end)
            end
          end)

        {:ok, results}
      end)
      |> Repo.transaction(timeout: :infinity)

    case result do
      {:ok, %{library: lib, skills: skills, role_profiles: rps, role_skills: rss}} ->
        Mix.shell().info("""
        Import complete!
          Library: #{lib.name} (#{lib.id})
          Skills: #{length(skills)}
          Role Profiles: #{length(rps)}
          Role-Skill Mappings: #{length(rss)}
        """)

      {:error, step, changeset, _} ->
        Mix.shell().error("Import failed at step #{step}:")
        Mix.shell().error(inspect(changeset))
        exit({:shutdown, 1})
    end
  end

  # --- XLSX Parsers ---

  defp parse_skills(file) do
    # Sheet 2 (index 2) = Skills to Job Roles Mapping
    {:ok, tid} = Xlsxir.extract(file, 2)
    rows = Xlsxir.get_list(tid)
    Xlsxir.close(tid)

    # Data rows start at index 7 (after headers)
    rows
    |> Enum.drop(7)
    |> Enum.reject(fn r -> Enum.all?(r, &is_nil/1) end)
    |> Enum.map(fn row ->
      pl_descriptions =
        Enum.zip(1..5, Enum.slice(row, 5..9))
        |> Enum.reject(fn {_, v} -> is_nil(v) or not is_binary(v) or v == "Y" end)
        |> Enum.map(fn {level, desc} ->
          %{
            "level" => level,
            "level_name" => "",
            "level_description" =>
              desc
              |> String.split(~r/\r?\n/)
              |> Enum.map(fn line ->
                line
                |> String.trim()
                |> String.trim_leading("−")
                |> String.trim_leading("–")
                |> String.trim_leading("-")
                |> String.trim()
              end)
              |> Enum.reject(&(&1 == ""))
              |> Enum.join(" — ")
          }
        end)

      %{
        name: safe_trim(Enum.at(row, 3)),
        category: safe_trim(Enum.at(row, 1)),
        cluster: safe_trim(Enum.at(row, 2)),
        description: safe_trim(Enum.at(row, 4)),
        proficiency_levels: pl_descriptions,
        status: "published"
      }
    end)
    |> Enum.reject(fn s -> is_nil(s.name) or s.name == "" end)
  end

  defp parse_roles(file) do
    sub_sector_names = @sub_sector_columns

    # Job roles are in Sheet 1 (index 1)
    {:ok, tid} = Xlsxir.extract(file, 1)
    rows = Xlsxir.get_list(tid)
    Xlsxir.close(tid)

    rows
    |> Enum.drop(6)
    |> Enum.reject(fn r -> Enum.all?(r, &is_nil/1) end)
    |> Enum.filter(fn r -> Enum.at(r, 1) != nil end)
    |> Enum.map(fn row ->
      sub_sectors =
        Enum.zip(sub_sector_names, Enum.slice(row, 6..12))
        |> Enum.filter(fn {_, v} -> v == "Y" end)
        |> Enum.map(fn {name, _} -> name end)

      %{
        name: safe_trim(Enum.at(row, 3)),
        role_family: safe_trim(Enum.at(row, 2)),
        purpose: safe_trim(Enum.at(row, 4)),
        description: safe_trim(Enum.at(row, 5)),
        metadata: %{"sub_sectors" => sub_sectors, "source" => "FSFM XLSX import"}
      }
    end)
    |> Enum.reject(fn r -> is_nil(r.name) or r.name == "" end)
  end

  defp parse_mapping(file) do
    # Use Sheet 3 (Job Roles → Skills) as it's easier to parse per-role
    {:ok, tid} = Xlsxir.extract(file, 2)
    rows = Xlsxir.get_list(tid)
    Xlsxir.close(tid)

    # Row 7 (index 6) has role names starting at column 11
    role_name_row = Enum.at(rows, 6)

    # Data rows start at index 7
    data_rows =
      rows
      |> Enum.drop(7)
      |> Enum.reject(fn r -> Enum.all?(r, &is_nil/1) end)

    # For each skill row, collect which roles have "Y"
    # Columns 11+ correspond to role names
    skill_to_roles =
      Enum.map(data_rows, fn row ->
        skill_name = safe_trim(Enum.at(row, 3))
        if skill_name, do: {skill_name, row}, else: nil
      end)
      |> Enum.reject(&is_nil/1)

    # Build role_name -> [skill_names] from skill rows
    role_names_with_idx =
      role_name_row
      |> Enum.with_index()
      |> Enum.filter(fn {v, i} -> i >= 11 and is_binary(v) and String.trim(v) != "" end)

    role_to_skills =
      Enum.reduce(skill_to_roles, %{}, fn {skill_name, row}, acc ->
        Enum.reduce(role_names_with_idx, acc, fn {role_name, col_idx}, acc2 ->
          if Enum.at(row, col_idx) == "Y" do
            Map.update(acc2, role_name, [skill_name], &[skill_name | &1])
          else
            acc2
          end
        end)
      end)

    Enum.map(role_to_skills, fn {role_name, skill_names} ->
      {role_name, Enum.reverse(skill_names)}
    end)
  end

  defp safe_trim(nil), do: nil
  defp safe_trim(v) when is_binary(v), do: String.trim(v)
  defp safe_trim(v), do: v

  # Collapse whitespace, newlines, and normalize for comparison
  defp normalize_name(name) do
    name
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.replace(~r/[-–—]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.downcase()
  end

  # Fuzzy match: try substring/starts-with first, then Jaro distance
  defp fuzzy_match(key, name_map, original_name) do
    # First try: one name starts with the other (handles truncation)
    substring_match =
      Enum.find(name_map, fn {k, _} ->
        String.starts_with?(k, key) or String.starts_with?(key, k)
      end)

    case substring_match do
      {_, matched} ->
        Mix.shell().info("  FUZZY: '#{original_name}' -> '#{matched.name}' (prefix match)")
        matched

      nil ->
        # Fallback: Jaro distance
        {best_score, best_key} =
          name_map
          |> Map.keys()
          |> Enum.map(fn k -> {String.jaro_distance(key, k), k} end)
          |> Enum.max_by(&elem(&1, 0))

        if best_score >= 0.88 do
          matched = Map.get(name_map, best_key)

          Mix.shell().info(
            "  FUZZY: '#{original_name}' -> '#{matched.name}' (jaro: #{Float.round(best_score, 3)})"
          )

          matched
        else
          nil
        end
    end
  end
end
