defmodule RhoFrameworks.Tools.LibraryTools do
  @moduledoc """
  Library-related tools for managing skill libraries.

  Uses the `Rho.Tool` DSL to define tools with minimal boilerplate.
  Each tool receives atom-keyed args (cast from the declared schema)
  and a `Rho.Context` with `organization_id`, `session_id`, `agent_id`.
  """

  use Rho.Tool

  alias RhoFrameworks.Library
  alias RhoFrameworks.Library.{Editor, Operations}
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.Runtime
  alias Rho.Stdlib.DataTable

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
            version: lib.version,
            published_at: lib.published_at && to_string(lib.published_at),
            skill_count: lib.skill_count,
            updated_at: to_string(lib.updated_at)
          }
        end)

      {:ok, Jason.encode!(result)}
    end)
  end

  tool :create_library,
       "Create a new mutable skill library and initialize the 'library' data table for editing. " <>
         "Then call save_and_generate with the skeleton JSON." do
    param(:name, :string, required: true, doc: "Library name")
    param(:description, :string, doc: "Brief description")

    run(fn args, ctx ->
      rt = Runtime.from_rho_context(ctx)
      params = %{name: args[:name], description: args[:description] || ""}

      case Editor.create(params, rt) do
        {:ok, %{library: lib, table: _spec, table_error: reason}} ->
          {:ok, "Created '#{lib.name}' (id: #{lib.id}), table init failed: #{inspect(reason)}"}

        {:ok, %{library: lib, table: spec}} ->
          %Rho.ToolResponse{
            text: "Created '#{lib.name}' (id: #{lib.id}), table: '#{spec.name}'.",
            effects: [
              %Rho.Effect.OpenWorkspace{key: :data_table},
              %Rho.Effect.Table{
                table_name: spec.name,
                schema_key: spec.schema_key,
                mode_label: spec.mode_label,
                rows: []
              }
            ]
          }

        {:error, {:validation, errors}} ->
          {:error, "Failed: #{inspect(errors)}"}
      end
    end)
  end

  tool :browse_library,
       "List skills in a library, optionally filtered by category or status. " <>
         "Provide either library_id (preferred) or library_name." do
    param(:library_id, :string, doc: "Library ID (preferred — from list_libraries)")
    param(:library_name, :string, doc: "Library name (resolved if library_id is omitted)")
    param(:category, :string, doc: "Filter by category")
    param(:status, :string, doc: "Filter by status: draft, published, archived")

    run(fn args, ctx ->
      case resolve_library_for_browse(ctx.organization_id, args) do
        {:ok, lib} ->
          opts =
            []
            |> maybe_opt(:category, args[:category])
            |> maybe_opt(:status, args[:status])

          skills = Library.browse_library(lib.id, opts)
          {:ok, Jason.encode!(skills)}

        {:error, reason} ->
          {:error, reason}
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
      rt = Runtime.from_rho_context(ctx)

      # Resolve the library first so we can derive the table name
      lib =
        case args[:library_id] do
          nil -> Library.get_or_create_default_library(rt.organization_id)
          id -> Library.get_library(rt.organization_id, id)
        end

      case lib do
        nil ->
          {:error, "Library not found"}

        lib ->
          tbl = Editor.table_name(lib.name)
          params = %{library_id: lib.id, table_name: tbl}

          case Editor.save_table(params, rt) do
            {:ok, %{saved_count: count, draft_library_id: draft_id}} when is_binary(draft_id) ->
              %Rho.ToolResponse{
                text: "Saved #{count} skill(s), draft created (#{draft_id}).",
                effects: [
                  %Rho.Effect.Table{
                    table_name: tbl,
                    schema_key: :skill_library,
                    mode_label: "Skill Library (draft)",
                    rows: [],
                    append?: true
                  }
                ]
              }

            {:ok, %{saved_count: count}} ->
              %Rho.ToolResponse{
                text: "Saved #{count} skill(s).",
                effects: [
                  %Rho.Effect.Table{
                    table_name: tbl,
                    schema_key: :skill_library,
                    mode_label: "Skill Library (saved)",
                    rows: [],
                    append?: true
                  }
                ]
              }

            {:error, :not_found} ->
              {:error, "Library not found"}

            {:error, {:not_running, tbl}} ->
              {:error, "No '#{tbl}' table is active — load a library first with load_library."}

            {:error, {:empty_table, tbl}} ->
              {:error, "The '#{tbl}' table is empty — nothing to save"}

            {:error, {:save_failed, step, changeset}} ->
              {:error, "Save failed at #{step}: #{inspect(changeset)}"}
          end
      end
    end)
  end

  tool :save_and_generate,
       "Save a skill skeleton to the library table AND spawn proficiency writers " <>
         "for each category in a single step. Returns agent_ids — call await_all to collect results. " <>
         "Call AFTER create_library." do
    param(:skills_json, :string,
      required: true,
      doc:
        ~s(JSON array: [{"category":"...","cluster":"...","skill_name":"...","skill_description":"..."},...]  )
    )

    param(:levels, :integer, doc: "Number of proficiency levels to generate (default: 5)")
    param(:library_name, :string, required: true, doc: "Library name (from create_library)")

    run(fn args, ctx ->
      rt = Runtime.from_rho_context(ctx)

      params = %{
        skills_json: args[:skills_json] || "[]",
        levels: args[:levels] || 5,
        library_name: args[:library_name]
      }

      case Operations.save_and_generate(params, rt) do
        {:ok, %{rows_added: count, table_name: table_name, workers: workers}} ->
          agent_ids = Enum.map(workers, & &1.agent_id)

          %Rho.ToolResponse{
            text:
              "Saved #{count} skeleton(s), spawned #{length(workers)} writer(s). IDs: #{Jason.encode!(agent_ids)}",
            effects: [
              %Rho.Effect.Table{
                table_name: table_name,
                schema_key: :skill_library,
                rows: [],
                append?: true
              }
            ]
          }

        {:error, :empty_list} ->
          {:error, "No valid data. Ensure skills_json is a valid JSON array."}

        {:error, :not_a_list} ->
          {:error, "No valid data. Ensure skills_json is a valid JSON array."}

        {:error, {:json_decode, _msg}} ->
          {:error, "No valid data. Ensure skills_json is a valid JSON array."}

        {:error, {:missing_required_keys, _keys, _count}} ->
          {:error,
           "No valid data. Ensure skills_json is a valid JSON array with category and skill_name."}

        {:error, reason} ->
          {:error, "Failed to save skeleton: #{inspect(reason)}"}
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

              {:ok, "Loaded '#{lib.name}' (immutable, #{skill_count} skills#{role_msg})."}

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
          {:ok, "Forked '#{lib.name}' — #{skill_count} skills."}

        {:error, _step, reason, _} ->
          {:error, "Fork failed: #{inspect(reason)}"}
      end
    end)
  end

  tool :load_library,
       "Load a library into the data table as structured skill rows for editing. " <>
         "Switches to skill_library schema. Replaces current data." do
    param(:library_id, :string, doc: "Library ID to load (use this OR library_name)")

    param(:library_name, :string,
      doc: "Library name — loads draft, falls back to latest published"
    )

    param(:version, :string,
      doc: "Specific version to load (e.g. '2026.04'). Requires library_name."
    )

    param(:category, :string, doc: "Filter by category")

    run(fn args, ctx ->
      lib =
        cond do
          args[:library_id] ->
            Library.get_library(ctx.organization_id, args[:library_id])

          args[:library_name] ->
            Library.resolve_library(ctx.organization_id, args[:library_name], args[:version])

          true ->
            nil
        end

      case lib do
        nil ->
          {:error, "Library not found"}

        lib ->
          opts = maybe_opt([], :category, args[:category])
          rows = Library.load_library_rows(lib.id, opts)

          if rows == [] do
            {:error, "Library '#{lib.name}' has no skills"}
          else
            version_label =
              if lib.version, do: " v#{lib.version}", else: " (draft)"

            table_name = library_table_name(lib.name)

            case DataTable.ensure_table(
                   ctx.session_id,
                   table_name,
                   DataTableSchemas.library_schema()
                 ) do
              :ok ->
                %Rho.ToolResponse{
                  text:
                    "'#{lib.name}'#{version_label} — #{length(rows)} skills, table: '#{table_name}'.",
                  effects: [
                    %Rho.Effect.OpenWorkspace{key: :data_table},
                    %Rho.Effect.Table{
                      table_name: table_name,
                      schema_key: :skill_library,
                      mode_label: "Skill Library — #{lib.name}#{version_label}",
                      rows: rows
                    }
                  ]
                }

              {:error, reason} ->
                {:error, "Failed to prepare 'library' table: #{inspect(reason)}"}
            end
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
       "Preview combining multiple source libraries. Always returns a preview summary — " <>
         "never auto-commits. Present the preview to the user and get approval before calling combine_libraries_commit." do
    param(:source_library_ids_json, :string,
      required: true,
      doc: ~s(JSON array of library IDs, e.g. ["id1", "id2"])
    )

    param(:new_name, :string, required: true, doc: "Name for the combined library")
    param(:description, :string, doc: "Optional description")

    run(fn args, ctx ->
      raw = args[:source_library_ids_json] || "[]"
      new_name = args[:new_name]
      _description = args[:description]

      case Jason.decode(raw) do
        {:ok, ids} when is_list(ids) and ids != [] ->
          case Library.combine_preview(ctx.organization_id, ids) do
            {:ok, %{conflicts: [], stats: stats} = preview} ->
              # No conflicts — return preview for user approval
              source_summary =
                preview.sources
                |> Enum.map(fn s -> "#{s.name} (#{s.skill_count} skills)" end)
                |> Enum.join(" + ")

              {:ok,
               "Preview: #{source_summary} → '#{new_name}'. #{stats.total} skills, no conflicts."}

            {:ok, %{conflicts: conflicts, stats: stats} = preview} ->
              # Conflicts found — load into data table for visual resolution
              conflict_rows =
                Enum.map(conflicts, fn c ->
                  %{
                    id: "#{c.skill_a.id}:#{c.skill_b.id}",
                    category: c.skill_a.category,
                    confidence: to_string(c.confidence),
                    skill_a_id: c.skill_a.id,
                    skill_a_name: c.skill_a.name,
                    skill_a_description: c.skill_a.description || "",
                    skill_a_source: c.skill_a.source_library_name,
                    skill_a_levels: c.skill_a.level_count,
                    skill_a_roles: c.skill_a.role_count,
                    skill_b_id: c.skill_b.id,
                    skill_b_name: c.skill_b.name,
                    skill_b_description: c.skill_b.description || "",
                    skill_b_source: c.skill_b.source_library_name,
                    skill_b_levels: c.skill_b.level_count,
                    skill_b_roles: c.skill_b.role_count,
                    resolution: "unresolved"
                  }
                end)

              # Ensure the combine_preview table exists and load conflict rows
              _ =
                DataTable.ensure_table(
                  ctx.session_id,
                  "combine_preview",
                  DataTableSchemas.combine_preview_schema()
                )

              source_summary =
                preview.sources
                |> Enum.map(fn s -> "#{s.name} (#{s.skill_count} skills)" end)
                |> Enum.join(" + ")

              %Rho.ToolResponse{
                text:
                  "#{stats.conflicted} conflict(s), #{stats.clean} clean — #{source_summary}.",
                effects: [
                  %Rho.Effect.OpenWorkspace{key: :data_table},
                  %Rho.Effect.Table{
                    table_name: "combine_preview",
                    schema_key: :combine_conflicts,
                    mode_label: "Combine: #{new_name}",
                    rows: conflict_rows
                  }
                ]
              }
          end

        _ ->
          {:error, "Provide a JSON array of at least 1 library ID."}
      end
    end)
  end

  tool :combine_libraries_commit,
       "Commit a combined library after resolving conflicts. " <>
         "Pass resolutions_json explicitly, or set to \"auto\" to read from the data table." do
    param(:source_library_ids_json, :string,
      required: true,
      doc: ~s(JSON array of source library IDs)
    )

    param(:new_name, :string, required: true, doc: "Name for the combined library")
    param(:description, :string, doc: "Optional description")

    param(:resolutions_json, :string,
      doc: ~s(JSON array of resolutions, or "auto" to read from the combine_preview data table)
    )

    run(fn args, ctx ->
      with {:ok, ids} when is_list(ids) and ids != [] <-
             Jason.decode(args[:source_library_ids_json] || "[]") do
        resolutions = resolve_resolutions(args[:resolutions_json], ctx.session_id)
        opts = maybe_opt([], :description, args[:description])

        unresolved =
          Enum.count(resolutions, fn r -> r["action"] in [nil, "", "unresolved"] end)

        if unresolved > 0 do
          {:error,
           "#{unresolved} conflict(s) still unresolved. " <>
             "Resolve all conflicts in the Skills Editor panel before committing."}
        else
          case Library.combine_commit(
                 ctx.organization_id,
                 ids,
                 args[:new_name],
                 resolutions,
                 opts
               ) do
            {:ok, %{library: lib, skill_count: count}} ->
              {:ok, "Created '#{lib.name}' (#{lib.id}) — #{count} skills."}

            {:error, reason} ->
              {:error, "Combine commit failed: #{inspect(reason)}"}
          end
        end
      else
        _ -> {:error, "Invalid source_library_ids_json."}
      end
    end)
  end

  # Read resolutions from explicit JSON or from the combine_preview data table
  defp resolve_resolutions(nil, session_id), do: read_resolutions_from_table(session_id)
  defp resolve_resolutions("", session_id), do: read_resolutions_from_table(session_id)
  defp resolve_resolutions("auto", session_id), do: read_resolutions_from_table(session_id)

  defp resolve_resolutions(json, _session_id) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp read_resolutions_from_table(session_id) do
    case DataTable.get_rows(session_id, table: "combine_preview") do
      {:ok, rows} ->
        Enum.map(rows, fn row ->
          resolution = get_in_row(row, :resolution)

          {action, keep} =
            case resolution do
              "merge_a" -> {"merge", get_in_row(row, :skill_a_id)}
              "merge_b" -> {"merge", get_in_row(row, :skill_b_id)}
              "keep_both" -> {"keep_both", nil}
              _ -> {"unresolved", nil}
            end

          %{
            "skill_a_id" => get_in_row(row, :skill_a_id),
            "skill_b_id" => get_in_row(row, :skill_b_id),
            "action" => action,
            "keep" => keep
          }
        end)

      _ ->
        []
    end
  end

  defp get_in_row(row, key) when is_atom(key) do
    Map.get(row, key) || Map.get(row, Atom.to_string(key))
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
          {:ok, "Merged. Source deleted."}

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
        {:ok, _} -> {:ok, "Dismissed."}
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

  # ── Versioning Tools ───────────────────────────────────────────────────

  tool :publish_library_version,
       "Publish the current draft library as a versioned, immutable snapshot. " <>
         "Once published, the library cannot be edited — create a new draft to make changes." do
    param(:library_id, :string, required: true, doc: "Draft library ID to publish")

    param(:version_tag, :string,
      required: false,
      doc: "Version tag, e.g. '2026.1'. Format: YYYY.N (auto-generated if omitted)"
    )

    param(:notes, :string, doc: "Optional publish notes")

    run(fn args, ctx ->
      # Sync data table rows to the draft before publishing,
      # so in-memory edits (add_rows, update_cells) aren't lost.
      library_id = args[:library_id]

      # Look up the library to derive the correct named table
      lib = Library.get_library(ctx.organization_id, library_id)
      table_name = if lib, do: library_table_name(lib.name), else: "library"

      case DataTable.get_rows(ctx.session_id, table: table_name) do
        rows when is_list(rows) and rows != [] ->
          Library.save_to_library(library_id, rows)

        _ ->
          :ok
      end

      version_tag = args[:version_tag]

      case Library.publish_version(
             ctx.organization_id,
             library_id,
             version_tag,
             notes: args[:notes]
           ) do
        {:ok, lib} ->
          {:ok, "Published '#{lib.name}' v#{lib.version}."}

        {:error, :not_found} ->
          {:error, "Library not found"}

        {:error, :already_published, msg} ->
          {:error, msg}

        {:error, :version_exists, msg} ->
          {:error, msg}

        {:error, changeset} ->
          {:error, "Publish failed: #{inspect(changeset)}"}
      end
    end)
  end

  tool :create_library_draft,
       "Create a new mutable draft from the latest published version of a library. " <>
         "Deep-copies all skills. Fails if a draft already exists." do
    param(:library_name, :string, required: true, doc: "Library name to create a draft for")
    param(:description, :string, doc: "Optional description override for the draft")

    run(fn args, ctx ->
      opts = maybe_opt([], :description, args[:description])

      case Library.create_draft_from_latest(ctx.organization_id, args[:library_name], opts) do
        {:ok, %{library: draft, skill_count: count}} ->
          {:ok, "Draft '#{draft.name}' created — #{count} skills."}

        {:error, :draft_exists, msg} ->
          {:error, msg}

        {:error, :no_published_version, msg} ->
          {:error, msg}

        {:error, _step, reason} ->
          {:error, "Failed to create draft: #{inspect(reason)}"}
      end
    end)
  end

  tool :list_library_versions,
       "List all published versions of a library by name, newest first." do
    param(:library_name, :string, required: true, doc: "Library name")

    run(fn args, ctx ->
      versions = Library.list_versions(ctx.organization_id, args[:library_name])
      draft = Library.get_draft(ctx.organization_id, args[:library_name])

      result = %{
        library_name: args[:library_name],
        draft: if(draft, do: %{id: draft.id, updated_at: to_string(draft.updated_at)}, else: nil),
        published_versions: versions
      }

      {:ok, Jason.encode!(result)}
    end)
  end

  tool :set_default_library_version,
       "Set a published library version as the default. " <>
         "When resolving a library by name without a version, the default version is used " <>
         "if no draft exists. Only one default per library name." do
    param(:library_id, :string,
      required: true,
      doc: "Published library version ID to set as default"
    )

    run(fn args, ctx ->
      case Library.set_default_version(ctx.organization_id, args[:library_id]) do
        {:ok, lib} ->
          {:ok, "Default set: '#{lib.name}' v#{lib.version}."}

        {:error, :not_found} ->
          {:error, "Library not found"}

        {:error, :not_published, msg} ->
          {:error, msg}

        {:error, reason} ->
          {:error, "Failed: #{inspect(reason)}"}
      end
    end)
  end

  tool :diff_library_versions,
       "Compare two versions of the same library. Shows added, removed, and modified skills. " <>
         "Use version 'draft' or omit to compare against the current draft." do
    param(:library_name, :string, required: true, doc: "Library name")
    param(:version_a, :string, required: true, doc: "First version (e.g. '2026.01' or 'draft')")
    param(:version_b, :string, required: true, doc: "Second version (e.g. '2026.04' or 'draft')")

    run(fn args, ctx ->
      version_a = if args[:version_a] == "draft", do: nil, else: args[:version_a]
      version_b = if args[:version_b] == "draft", do: nil, else: args[:version_b]

      case Library.diff_versions(ctx.organization_id, args[:library_name], version_a, version_b) do
        {:ok, diff} -> {:ok, Jason.encode!(diff)}
        {:error, :not_found, msg} -> {:error, msg}
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

  @doc false
  defdelegate library_table_name(lib_name), to: Editor, as: :table_name

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, _key, ""), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # browse_library accepts either library_id or library_name.
  # Tries id first, then falls back to name via Library.resolve_library/2.
  defp resolve_library_for_browse(org_id, args) do
    id = blank_to_nil(args[:library_id])
    name = blank_to_nil(args[:library_name])

    cond do
      id ->
        case Library.get_library(org_id, id) do
          nil -> {:error, "Library not found for library_id=#{id}"}
          lib -> {:ok, lib}
        end

      name ->
        case Library.resolve_library(org_id, name) do
          nil ->
            {:error,
             "Library not found for library_name=#{inspect(name)}. " <>
               "Call list_libraries to see available libraries."}

          lib ->
            {:ok, lib}
        end

      true ->
        {:error,
         "Provide library_id (preferred) or library_name. " <>
           "Call list_libraries first if you don't know the id."}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
end
