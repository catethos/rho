defmodule RhoFrameworks.Tools.LibraryTools do
  @moduledoc """
  Library-related tools for managing skill libraries.

  Uses the `Rho.Tool` DSL to define tools with minimal boilerplate.
  Each tool receives atom-keyed args (cast from the declared schema)
  and a `Rho.Context` with `organization_id`, `session_id`, `agent_id`.
  """

  use Rho.Tool

  alias RhoFrameworks.Library
  alias Rho.Stdlib.Plugins.DataTable, as: DT

  # ── Library Tools ──────────────────────────────────────────────────────

  tool :list_libraries, "List all skill libraries for the current organization." do
    run(fn _args, ctx ->
      libraries = Library.list_libraries(ctx.organization_id)

      result =
        Enum.map(libraries, fn lib ->
          %{
            id: lib.id,
            name: lib.name,
            description: lib.description,
            type: lib.type,
            immutable: lib.immutable,
            skill_count: lib.skill_count,
            updated_at: to_string(lib.updated_at)
          }
        end)

      {:ok, Jason.encode!(result)}
    end)
  end

  tool :create_library,
       "Create a new mutable skill library. Use for organizing skills by domain." do
    param(:name, :string, required: true, doc: "Library name")
    param(:description, :string, doc: "Brief description")

    run(fn args, ctx ->
      name = args[:name]
      description = args[:description] || ""

      case Library.create_library(ctx.organization_id, %{name: name, description: description}) do
        {:ok, lib} -> {:ok, "Created library '#{lib.name}' (id: #{lib.id})"}
        {:error, changeset} -> {:error, "Failed: #{inspect(changeset.errors)}"}
      end
    end)
  end

  tool :browse_library,
       "List skills in a library, optionally filtered by category or status. " <>
         "MUST be called before generating skills for a new role — use existing names as vocabulary." do
    param(:library_id, :string, required: true, doc: "Library ID")
    param(:category, :string, doc: "Filter by category")
    param(:status, :string, doc: "Filter by status: draft, published, archived")

    run(fn args, ctx ->
      case Library.get_library(ctx.organization_id, args[:library_id]) do
        nil ->
          {:error, "Library not found"}

        _lib ->
          opts =
            []
            |> maybe_opt(:category, args[:category])
            |> maybe_opt(:status, args[:status])

          skills = Library.browse_library(args[:library_id], opts)
          {:ok, Jason.encode!(skills)}
      end
    end)
  end

  tool :save_to_library,
       "Save current data table rows (library mode) to a skill library. " <>
         "Skills are saved as published. Creates a default library if none specified." do
    param(:library_id, :string,
      doc: "Target library ID. Omit to use or create the default library."
    )

    run(fn args, ctx ->
      library_id =
        case args[:library_id] do
          nil -> Library.get_or_create_default_library(ctx.organization_id).id
          id -> id
        end

      rows = DT.read_rows(ctx.session_id)

      if rows == [] do
        {:error, "Data table is empty — nothing to save"}
      else
        case Library.save_to_library(library_id, rows) do
          {:ok, %{skills: skills}} ->
            count = length(skills)

            %Rho.ToolResponse{
              text: "Saved #{count} skill(s) to library (status: published)",
              effects: [
                %Rho.Effect.Table{
                  schema_key: :skill_library,
                  mode_label: "Skill Library (saved)",
                  rows: [],
                  append?: true
                }
              ]
            }

          {:error, step, changeset, _} ->
            {:error, "Save failed at #{step}: #{inspect(changeset)}"}
        end
      end
    end)
  end

  tool :load_template,
       "Load a standard framework template (e.g. 'sfia_v8') as an immutable library. " <>
         "Fork it to create a mutable working copy." do
    param(:source_key, :string, required: true, doc: "Template key, e.g. 'sfia_v8'")

    run(fn args, ctx ->
      case load_template_data(args[:source_key]) do
        {:ok, template_data} ->
          case Library.load_template(ctx.organization_id, args[:source_key], template_data) do
            {:ok, %{library: lib, skills: skills} = result} ->
              skill_count = length(skills)
              role_count = length(Map.get(result, :role_profiles, []))

              role_msg =
                if role_count > 0,
                  do: " and #{role_count} reference role profiles",
                  else: ""

              {:ok,
               "Loaded '#{lib.name}' as immutable library with #{skill_count} skills#{role_msg}. " <>
                 "Fork it with fork_library to create a mutable working copy."}

            {:error, _step, changeset, _} ->
              {:error, "Load failed: #{inspect(changeset)}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  tool :fork_library,
       "Fork a library (typically an immutable standard) into a mutable working copy. " <>
         "Deep-copies skills and optionally role profiles. " <>
         "Pass categories_json to only copy skills in selected categories." do
    param(:source_library_id, :string, required: true, doc: "Library to fork")
    param(:new_name, :string, required: true, doc: "Name for the fork")

    param(:include_roles, :boolean, doc: "Also copy role profiles? Default: true")

    param(:categories_json, :string,
      doc:
        ~s(JSON array of category names to include, e.g. ["Software Development", "Data Management"]. Omit to copy all.)
    )

    run(fn args, ctx ->
      include_roles = if args[:include_roles] == nil, do: true, else: args[:include_roles]

      categories =
        case args[:categories_json] do
          nil ->
            :all

          raw ->
            case Jason.decode(raw) do
              {:ok, list} when is_list(list) and list != [] -> list
              _ -> :all
            end
        end

      opts = [include_roles: include_roles, categories: categories]

      case Library.fork_library(
             ctx.organization_id,
             args[:source_library_id],
             args[:new_name],
             opts
           ) do
        {:ok, %{library: lib, skills: skill_map}} ->
          skill_count = map_size(skill_map)
          {:ok, "Forked into '#{lib.name}' with #{skill_count} skills (mutable)"}

        {:error, _step, reason, _} ->
          {:error, "Fork failed: #{inspect(reason)}"}
      end
    end)
  end

  tool :load_library,
       "Load a library into the data table as structured skill rows for editing. " <>
         "Switches to skill_library schema. Replaces current data." do
    param(:library_id, :string, required: true, doc: "Library ID to load")
    param(:category, :string, doc: "Filter by category")

    run(fn args, ctx ->
      case Library.get_library(ctx.organization_id, args[:library_id]) do
        nil ->
          {:error, "Library not found"}

        lib ->
          opts = maybe_opt([], :category, args[:category])
          rows = Library.load_library_rows(args[:library_id], opts)

          if rows == [] do
            {:error, "Library '#{lib.name}' has no skills"}
          else
            %Rho.ToolResponse{
              text:
                "Loaded library '#{lib.name}' with #{length(rows)} skills into the data table",
              effects: [
                %Rho.Effect.OpenWorkspace{key: :data_table},
                %Rho.Effect.Table{
                  schema_key: :skill_library,
                  mode_label: "Skill Library — #{lib.name}",
                  rows: rows
                }
              ]
            }
          end
      end
    end)
  end

  tool :diff_library,
       "Diff a forked library against its source. Shows added, removed, and modified skills." do
    param(:library_id, :string, required: true, doc: "The forked library ID")

    run(fn args, ctx ->
      case Library.diff_against_source(ctx.organization_id, args[:library_id]) do
        {:ok, diff} -> {:ok, Jason.encode!(diff)}
        {:error, :no_source, msg} -> {:error, msg}
      end
    end)
  end

  tool :search_skills_cross_library,
       "Search skills across all org libraries by keyword. " <>
         "Results include library name and skill status." do
    param(:query, :string, required: true, doc: "Search keyword(s)")
    param(:category, :string, doc: "Filter by category")

    run(fn args, ctx ->
      query = args[:query] || ""
      opts = maybe_opt([], :category, args[:category])
      results = Library.search_skills_across(ctx.organization_id, query, opts)
      {:ok, Jason.encode!(results)}
    end)
  end

  tool :combine_libraries,
       "Create a new mutable library by copying skills from multiple source libraries. " <>
         "Sources are never modified. Use find_duplicates on the result to deduplicate." do
    param(:source_library_ids_json, :string,
      required: true,
      doc: ~s(JSON array of library IDs, e.g. ["id1", "id2"])
    )

    param(:new_name, :string, required: true, doc: "Name for the combined library")
    param(:description, :string, doc: "Optional description")

    run(fn args, ctx ->
      raw = args[:source_library_ids_json] || "[]"
      new_name = args[:new_name]
      description = args[:description]

      case Jason.decode(raw) do
        {:ok, ids} when is_list(ids) and ids != [] ->
          opts = maybe_opt([], :description, description)

          case Library.combine_libraries(ctx.organization_id, ids, new_name, opts) do
            {:ok, %{library: lib, skill_count: count}} ->
              {:ok,
               "Created '#{lib.name}' with #{count} skills copied from #{length(ids)} source libraries. " <>
                 "Sources unchanged. Run find_duplicates to identify overlaps."}

            {:error, reason} ->
              {:error, "Combine failed: #{inspect(reason)}"}
          end

        _ ->
          {:error, "Provide a JSON array of at least 1 library ID."}
      end
    end)
  end

  tool :find_duplicates,
       "Find duplicate skill pairs in a library. Returns pairs with confidence, " <>
         "detection method, role references, and level conflicts. " <>
         "Use depth='deep' for LLM-based semantic matching (slower but catches subtle duplicates)." do
    param(:library_id, :string, required: true, doc: "Library ID")

    param(:depth, :string,
      doc: "Detection depth: 'standard' (default, fast) or 'deep' (adds LLM semantic matching)"
    )

    run(fn args, ctx ->
      case Library.get_library(ctx.organization_id, args[:library_id]) do
        nil ->
          {:error, "Library not found"}

        _lib ->
          depth =
            case args[:depth] || "standard" do
              "deep" -> :deep
              _ -> :standard
            end

          dupes = Library.find_duplicates(args[:library_id], depth: depth)
          {:ok, Jason.encode!(dupes)}
      end
    end)
  end

  tool :merge_skills,
       "Merge two duplicate skills: absorb source into target. " <>
         "Repoints all role references, fills proficiency gaps. Source is deleted." do
    param(:source_id, :string, required: true, doc: "Skill to absorb (will be deleted)")
    param(:target_id, :string, required: true, doc: "Skill to keep")
    param(:new_name, :string, doc: "Rename the surviving skill (optional)")

    run(fn args, _ctx ->
      opts = maybe_opt([], :new_name, args[:new_name])

      case Library.merge_skills(args[:source_id], args[:target_id], opts) do
        {:ok, _multi} ->
          {:ok, "Merged successfully. Source skill deleted, references repointed to target."}

        {:error, :immutable_library, msg} ->
          {:error, msg}

        {:error, _step, reason, _} ->
          {:error, "Merge failed: #{inspect(reason)}"}
      end
    end)
  end

  tool :dismiss_duplicate,
       "Mark two skills as intentionally different. " <>
         "They won't be flagged as duplicates again." do
    param(:library_id, :string, required: true, doc: "Library ID")
    param(:skill_a_id, :string, required: true, doc: "First skill ID")
    param(:skill_b_id, :string, required: true, doc: "Second skill ID")

    run(fn args, _ctx ->
      case Library.dismiss_duplicate(args[:library_id], args[:skill_a_id], args[:skill_b_id]) do
        {:ok, _} -> {:ok, "Marked as intentionally different. Won't be flagged again."}
        {:error, changeset} -> {:error, "Failed: #{inspect(changeset.errors)}"}
      end
    end)
  end

  tool :consolidate_library,
       "Generate a consolidation report: duplicate pairs, draft skills needing descriptions, orphan skills." do
    param(:library_id, :string, required: true, doc: "Library ID")

    run(fn args, ctx ->
      case Library.get_library(ctx.organization_id, args[:library_id]) do
        nil -> {:error, "Library not found"}
        _lib -> {:ok, Jason.encode!(Library.consolidation_report(args[:library_id]))}
      end
    end)
  end

  # ── Template loading ───────────────────────────────────────────────────

  defp load_template_data(source_key) do
    templates_dir = Application.app_dir(:rho_frameworks, "priv/templates")
    path = Path.join(templates_dir, "#{source_key}.json")

    if File.exists?(path) do
      case Jason.decode!(File.read!(path)) do
        %{"name" => name, "skills" => skills} = data ->
          template = %{
            name: name,
            description: data["description"],
            skills:
              Enum.map(skills, fn skill ->
                %{
                  category: skill["category"] || "",
                  cluster: skill["cluster"] || "",
                  name: skill["name"] || "",
                  description: skill["description"] || "",
                  proficiency_levels:
                    Enum.map(skill["proficiency_levels"] || [], fn lvl ->
                      %{
                        "level" => lvl["level"] || 0,
                        "level_name" => lvl["level_name"] || lvl["name"] || "",
                        "level_description" =>
                          lvl["level_description"] || lvl["description"] || ""
                      }
                    end)
                }
              end),
            role_profiles:
              (data["role_profiles"] || [])
              |> Enum.map(fn rp ->
                %{
                  name: rp["name"],
                  role_family: rp["role_family"],
                  seniority_level: rp["seniority_level"],
                  seniority_label: rp["seniority_label"],
                  purpose: rp["purpose"],
                  skills:
                    Enum.map(rp["skills"] || [], fn rs ->
                      %{
                        skill_name: rs["skill_name"],
                        min_expected_level: rs["min_expected_level"] || 1,
                        required: Map.get(rs, "required", true)
                      }
                    end)
                }
              end)
          }

          {:ok, template}

        _ ->
          {:error, "Invalid template format"}
      end
    else
      {:error, "Template '#{source_key}' not found. Available: sfia_v8"}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, _key, ""), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
