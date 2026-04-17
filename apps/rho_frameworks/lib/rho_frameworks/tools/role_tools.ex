defmodule RhoFrameworks.Tools.RoleTools do
  @moduledoc """
  Role-related tools extracted from RhoFrameworks.Plugin.

  Uses the `Rho.Tool` DSL to define tools with minimal boilerplate.
  Provides tools for managing role profiles, career ladders, and gap analysis.
  All operations are scoped to the current organization via context.
  """

  use Rho.Tool

  alias RhoFrameworks.Roles
  alias RhoFrameworks.GapAnalysis
  alias RhoFrameworks.DataTableSchemas
  alias Rho.Stdlib.DataTable

  # ── Role Tools ──────────────────────────────────────────────────────────

  tool :save_role_profile,
       "Save the current data table (role mode) as a role profile. " <>
         "Skills are linked to the specified library. " <>
         "IMPORTANT: always pass library_id to avoid creating a duplicate 'Default Skills' library." do
    param(:name, :string, required: true, doc: "Role profile name")
    param(:role_family, :string, doc: "e.g. Engineering, Product")

    param(:seniority_level, :integer, doc: "1=Junior, 2=Mid, 3=Senior, 4=Staff, 5=Principal")

    param(:seniority_label, :string, doc: "e.g. Senior, Staff")
    param(:description, :string, doc: "Role overview")
    param(:purpose, :string, doc: "Why this role exists")

    param(:library_id, :string,
      required: true,
      doc: "Library ID where skills are stored. Use list_libraries to find it."
    )

    run(fn args, ctx ->
      name = args[:name]

      if is_nil(name) or name == "" do
        {:error, "Role profile name is required"}
      else
        case DataTable.get_rows(ctx.session_id, table: "role_profile") do
          {:error, :not_running} ->
            {:error, "No 'role_profile' table is active — load or clone a role profile first."}

          [] ->
            {:error, "The 'role_profile' table is empty — add skills first"}

          rows when is_list(rows) ->
            attrs = %{name: name}
            attrs = maybe_put(attrs, :role_family, args[:role_family])
            attrs = maybe_put(attrs, :seniority_level, args[:seniority_level])
            attrs = maybe_put(attrs, :seniority_label, args[:seniority_label])
            attrs = maybe_put(attrs, :description, args[:description])
            attrs = maybe_put(attrs, :purpose, args[:purpose])

            opts = maybe_opt([], :library_id, args[:library_id])

            case Roles.save_role_profile(ctx.organization_id, attrs, rows, opts) do
              {:ok, %{role_profile: rp, role_skills: skill_count}} ->
                version_note =
                  if rp.library_version,
                    do: " (pinned to library version: #{rp.library_version})",
                    else: ""

                {:ok, "Saved '#{rp.name}' — #{skill_count} skill(s)#{version_note}."}

              {:error, step, changeset, _} ->
                {:error, "Save failed at #{step}: #{inspect(changeset)}"}
            end
        end
      end
    end)
  end

  tool :load_role_profile,
       "Load a role profile into the data table by name. " <>
         "Switches to role profile schema. Replaces current data." do
    param(:name, :string, required: true, doc: "Role profile name")

    run(fn args, ctx ->
      name = args[:name]

      case Roles.load_role_profile(ctx.organization_id, name) do
        {:error, :not_found} ->
          {:error, "Role profile '#{name}' not found"}

        {:ok, %{role_profile: rp, rows: rows}} ->
          case DataTable.ensure_table(
                 ctx.session_id,
                 "role_profile",
                 DataTableSchemas.role_profile_schema()
               ) do
            :ok ->
              %Rho.ToolResponse{
                text: "'#{rp.name}' — #{length(rows)} skills, table: 'role_profile'.",
                effects: [
                  %Rho.Effect.OpenWorkspace{key: :data_table},
                  %Rho.Effect.Table{
                    table_name: "role_profile",
                    schema_key: :role_profile,
                    mode_label: "Role Profile — #{rp.name}",
                    rows: rows,
                    metadata: %{library_id: rp.library_id}
                  }
                ]
              }

            {:error, reason} ->
              {:error, "Failed to prepare 'role_profile' table: #{inspect(reason)}"}
          end
      end
    end)
  end

  tool :list_role_profiles,
       "List all role profiles for the current organization." do
    param(:role_family, :string, doc: "Filter by role family")

    run(fn args, ctx ->
      opts = maybe_opt([], :role_family, args[:role_family])
      profiles = Roles.list_role_profiles(ctx.organization_id, opts)
      {:ok, Jason.encode!(profiles)}
    end)
  end

  tool :find_similar_roles,
       "Find existing role profiles similar to a given name or description. " <>
         "Use before creating a new role to offer cloning from existing roles." do
    param(:query, :string, required: true, doc: "Role name or description to search for")

    run(fn args, ctx ->
      query = args[:query] || ""
      results = Roles.find_similar_roles(ctx.organization_id, query)
      {:ok, Jason.encode!(results)}
    end)
  end

  tool :start_role_profile_draft,
       "Initialize an empty 'role_profile' data table so you can build a fresh role " <>
         "from scratch. Use at the start of Path (a) bottom-up role creation BEFORE " <>
         "calling add_rows. All subsequent add_rows/update_cells/delete_rows calls must " <>
         "pass `table: \"role_profile\"`. Does not touch the database." do
    param(:mode_label, :string, doc: "Optional label shown in the tab strip")

    run(fn args, ctx ->
      label = args[:mode_label] || "New Role Profile (draft)"

      case DataTable.ensure_table(
             ctx.session_id,
             "role_profile",
             DataTableSchemas.role_profile_schema()
           ) do
        :ok ->
          %Rho.ToolResponse{
            text: "Empty 'role_profile' table ready.",
            effects: [
              %Rho.Effect.OpenWorkspace{key: :data_table},
              %Rho.Effect.Table{
                table_name: "role_profile",
                schema_key: :role_profile,
                mode_label: label,
                rows: []
              }
            ]
          }

        {:error, reason} ->
          {:error, "Failed to prepare 'role_profile' table: #{inspect(reason)}"}
      end
    end)
  end

  tool :clone_role_skills,
       "Copy skill selection from one or more existing role profiles. " <>
         "When multiple roles, unions skills and keeps the highest required level on overlap. " <>
         "Loads result into data table in role profile mode." do
    param(:role_profile_ids_json, :string,
      required: true,
      doc: ~s(JSON array of role profile IDs, e.g. ["id1", "id2"])
    )

    run(fn args, ctx ->
      raw = args[:role_profile_ids_json] || "[]"

      case Jason.decode(raw) do
        {:ok, ids} when is_list(ids) and ids != [] ->
          rows = Roles.clone_role_skills(ctx.organization_id, ids)

          case DataTable.ensure_table(
                 ctx.session_id,
                 "role_profile",
                 DataTableSchemas.role_profile_schema()
               ) do
            :ok ->
              %Rho.ToolResponse{
                text: "Cloned #{length(rows)} skills from #{length(ids)} role(s).",
                effects: [
                  %Rho.Effect.OpenWorkspace{key: :data_table},
                  %Rho.Effect.Table{
                    table_name: "role_profile",
                    schema_key: :role_profile,
                    mode_label: "New Role Profile (cloned)",
                    rows: rows
                  }
                ]
              }

            {:error, reason} ->
              {:error, "Failed to prepare 'role_profile' table: #{inspect(reason)}"}
          end

        _ ->
          {:error, "Provide a JSON array of at least 1 role profile ID."}
      end
    end)
  end

  tool :show_career_ladder,
       "Show role progression for a role family, ordered by seniority. " <>
         "Includes skill diffs between levels." do
    param(:role_family, :string, required: true, doc: "e.g. Engineering, Product")

    run(fn args, ctx ->
      role_family = args[:role_family]
      profiles = Roles.career_ladder(ctx.organization_id, role_family)

      result =
        Enum.map(profiles, fn p ->
          %{
            name: p.name,
            seniority_level: p.seniority_level,
            seniority_label: p.seniority_label,
            skill_count: MapSet.size(p.skill_set),
            new_skills: MapSet.to_list(p.new_skills),
            dropped_skills: MapSet.to_list(p.dropped_skills)
          }
        end)

      {:ok, Jason.encode!(result)}
    end)
  end

  tool :get_org_view,
       "Cross-role summary for the current organization: shared vs unique skills across " <>
         "all role profiles, role families, and per-role skill counts. Pure read. " <>
         "Use as a bootstrap 'what does this org look like?' call." do
    run(fn _args, ctx ->
      view = Roles.org_view(ctx.organization_id)
      {:ok, Jason.encode!(view)}
    end)
  end

  tool :gap_analysis,
       "Run skill gap analysis: compare a skill snapshot against a role profile's requirements. " <>
         "For individual or team analysis." do
    param(:role_profile_id, :string,
      required: true,
      doc: "Role profile ID to compare against"
    )

    param(:snapshot_json, :string,
      required: true,
      doc:
        ~s(JSON: {"person_id": {"skill_id": level, ...}} for one person, or {"person1": {...}, "person2": {...}} for team)
    )

    run(fn args, _ctx ->
      role_profile_id = args[:role_profile_id]
      raw = args[:snapshot_json] || "{}"

      case Jason.decode(raw) do
        {:ok, snapshots} when is_map(snapshots) ->
          people =
            Enum.map(snapshots, fn {person_id, skills} ->
              skill_map = Map.new(skills, fn {k, v} -> {k, v} end)
              {person_id, skill_map}
            end)

          result =
            if length(people) == 1 do
              {_id, snapshot} = hd(people)
              GapAnalysis.individual_gap(snapshot, role_profile_id)
            else
              GapAnalysis.team_gap(people, role_profile_id)
            end

          {:ok, Jason.encode!(result)}

        _ ->
          {:error, "Invalid JSON. Provide a map of person_id → {skill_id → level}."}
      end
    end)
  end

  tool :check_role_currency,
       "Check if a role profile's skills are current relative to the latest published library version." do
    param(:role_profile_id, :string, required: true, doc: "Role profile ID")

    run(fn args, ctx ->
      case Roles.check_version_currency(ctx.organization_id, args[:role_profile_id]) do
        {:ok, :current, details} ->
          {:ok, Jason.encode!(%{status: "current", details: details})}

        {:stale, details} ->
          {:ok, Jason.encode!(%{status: "stale", details: details})}

        {:error, :not_found} ->
          {:error, "Role profile not found"}

        {:error, :no_library, msg} ->
          {:error, msg}

        {:error, :library_deleted, msg} ->
          {:error, msg}
      end
    end)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, _key, ""), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
