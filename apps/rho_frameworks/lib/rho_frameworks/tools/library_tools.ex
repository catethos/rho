defmodule RhoFrameworks.Tools.LibraryTools do
  @moduledoc """
  Consolidated library tools — 9 tools covering all library operations.
  """

  use Rho.Tool

  alias RhoFrameworks.Library
  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.Roles
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.MapAccess
  alias RhoFrameworks.Scope
  alias RhoFrameworks.Workbench
  alias Rho.Stdlib.DataTable

  # ── manage_library ─────────────────────────────────────────────────────

  tool :manage_library,
       "Skill library CRUD." do
    param(:action, :string,
      required: true,
      doc: "list | create | delete | create_draft | publish"
    )

    param(:name, :string)
    param(:description, :string)
    param(:library_id, :string)
    param(:library_name, :string)
    param(:version_tag, :string)
    param(:notes, :string)

    run(fn args, ctx ->
      case args[:action] do
        "list" ->
          do_list_libraries(ctx)

        "create" ->
          do_create_library(args, ctx)

        "delete" ->
          do_delete_library(args, ctx)

        "create_draft" ->
          do_create_draft(args, ctx)

        "publish" ->
          do_publish(args, ctx)

        other ->
          {:error, "Unknown action: #{other}. Use: list, create, delete, create_draft, publish"}
      end
    end)
  end

  defp do_list_libraries(ctx) do
    libraries = Library.list_libraries(ctx.organization_id)

    result =
      Enum.map_join(libraries, "\n", fn lib ->
        version = if lib.version, do: "v#{lib.version}", else: "draft"
        flags = if lib.immutable, do: ", immutable", else: ""
        "- #{lib.name} (#{lib.id}) — #{lib.skill_count} skills, #{version}#{flags}"
      end)

    {:ok, result}
  end

  defp do_create_library(args, ctx) do
    rt = Scope.from_context(ctx)
    params = %{name: args[:name], description: args[:description] || ""}

    case Editor.create(params, rt) do
      {:ok, %{library: lib, table: _spec, table_error: reason}} ->
        {:ok, "Created '#{lib.name}' (id: #{lib.id}), table init failed: #{inspect(reason)}"}

      {:ok, %{library: lib, table: spec}} ->
        %Rho.ToolResponse{
          text: "Created library '#{lib.name}' (id: #{lib.id}).",
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
  end

  defp do_delete_library(args, ctx) do
    case Library.delete_library(ctx.organization_id, args[:library_id]) do
      {:ok, lib} -> {:ok, "Deleted library '#{lib.name}' (#{lib.id})."}
      {:error, :not_found} -> {:error, "Library not found"}
      {:error, changeset} -> {:error, "Delete failed: #{inspect(changeset)}"}
    end
  end

  defp do_create_draft(args, ctx) do
    name = args[:library_name] || args[:name]
    opts = maybe_opt([], :description, args[:description])

    case Library.create_draft_from_latest(ctx.organization_id, name, opts) do
      {:ok, %{library: draft, skill_count: count}} ->
        {:ok, "Draft '#{draft.name}' created — #{count} skills."}

      {:error, :draft_exists, msg} ->
        {:error, msg}

      {:error, :no_published_version, msg} ->
        {:error, msg}

      {:error, _step, reason} ->
        {:error, "Failed: #{inspect(reason)}"}
    end
  end

  # ── load_library ───────────────────────────────────────────────────────

  tool :load_library,
       "Load an EXISTING saved library from the DB into the `library:<name>` working table. " <>
         "Do NOT use after `generate_framework_skeletons` — the skeleton rows are already in the " <>
         "table; `save_framework` is what persists them to the DB. Use only for libraries that " <>
         "have already been saved or for template keys (e.g. sfia_v8)." do
    param(:library_name, :string, doc: "library name or template key (e.g. sfia_v8)")
    param(:version, :string)
    param(:category, :string)

    run(fn args, ctx ->
      name = args[:library_name]

      cond do
        is_nil(name) ->
          not_found_with_hints(ctx.organization_id, nil)

        template_key?(name) ->
          do_load_template(Map.put(args, :template_key, name), ctx)

        true ->
          do_load_library(args, ctx)
      end
    end)
  end

  defp do_load_template(args, ctx) do
    case load_template_data(args[:template_key]) do
      {:ok, template_data} ->
        case Library.load_template(ctx.organization_id, args[:template_key], template_data) do
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
  end

  defp do_load_library(args, ctx) do
    name = args[:library_name]

    lib =
      if name,
        do: Library.resolve_library(ctx.organization_id, name, args[:version]),
        else: nil

    case lib do
      nil ->
        not_found_with_hints(ctx.organization_id, name)

      lib ->
        opts = maybe_opt([], :category, args[:category])
        rows = Library.load_library_rows(lib.id, opts)

        if rows == [] do
          {:error, "Library '#{lib.name}' has no skills"}
        else
          version_label = if lib.version, do: " v#{lib.version}", else: " (draft)"
          table_name = library_table_name(lib.name)

          scope = Scope.from_context(ctx)

          with :ok <-
                 DataTable.ensure_table(
                   ctx.session_id,
                   table_name,
                   DataTableSchemas.library_schema()
                 ),
               {:ok, _} <- Workbench.replace_rows(scope, rows, table: table_name) do
            %Rho.ToolResponse{
              text:
                "'#{lib.name}'#{version_label} — #{length(rows)} skills, table: '#{table_name}'.",
              effects: [
                %Rho.Effect.OpenWorkspace{key: :data_table},
                %Rho.Effect.Table{
                  table_name: table_name,
                  schema_key: :skill_library,
                  mode_label: "Skill Library — #{lib.name}#{version_label}",
                  rows: [],
                  skip_write?: true
                }
              ]
            }
          else
            {:error, reason} -> {:error, "Failed to prepare table: #{inspect(reason)}"}
          end
        end
    end
  end

  defp do_publish(args, ctx) do
    library_id = args[:library_id]
    lib = Library.get_library(ctx.organization_id, library_id)
    table_name = if lib, do: library_table_name(lib.name), else: "library"

    # Sync data table rows before publishing
    case DataTable.get_rows(ctx.session_id, table: table_name) do
      rows when is_list(rows) and rows != [] -> Library.save_to_library(library_id, rows)
      _ -> :ok
    end

    case Library.publish_version(ctx.organization_id, library_id, args[:version_tag],
           notes: args[:notes]
         ) do
      {:ok, lib} -> {:ok, "Published '#{lib.name}' v#{lib.version}."}
      {:error, :not_found} -> {:error, "Library not found"}
      {:error, :already_published, msg} -> {:error, msg}
      {:error, :version_exists, msg} -> {:error, msg}
      {:error, changeset} -> {:error, "Publish failed: #{inspect(changeset)}"}
    end
  end

  # ── fork_library ───────────────────────────────────────────────────────

  tool :fork_library,
       "Fork skill library into editable copy." do
    param(:source_library_id, :string, required: true)
    param(:new_name, :string, required: true)
    param(:categories_json, :string, doc: "JSON array, omit for all")

    run(fn args, ctx ->
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

      opts = [categories: categories]

      case Library.fork_library(
             ctx.organization_id,
             args[:source_library_id],
             args[:new_name],
             opts
           ) do
        {:ok, %{library: lib, skills: count}} ->
          {:ok, "Forked '#{lib.name}' — #{count} skills."}

        {:error, _step, reason, _} ->
          {:error, "Fork failed: #{inspect(reason)}"}
      end
    end)
  end

  # ── browse_library ─────────────────────────────────────────────────────

  tool :browse_library,
       "Browse skills in a library or search across all libraries." do
    param(:library_id, :string, doc: "Library ID (single library browse)")
    param(:library_name, :string, doc: "Library name (resolved if no ID)")
    param(:query, :string, doc: "Search keyword — enables cross-library search")
    param(:category, :string, doc: "Filter by category")
    param(:status, :string, doc: "Filter: draft, published, archived")

    run(fn args, ctx ->
      cond do
        args[:query] ->
          opts = maybe_opt([], :category, args[:category])
          results = Library.search_skills_across(ctx.organization_id, args[:query], opts)
          {:ok, format_search_results(results)}

        args[:library_id] || args[:library_name] ->
          case resolve_library_for_browse(ctx.organization_id, args) do
            {:ok, lib} ->
              opts =
                []
                |> maybe_opt(:category, args[:category])
                |> maybe_opt(:status, args[:status])

              browse_library_or_index(lib, opts, args)

            {:error, reason} ->
              {:error, reason}
          end

        true ->
          summaries = Library.library_summary(ctx.organization_id)
          {:ok, format_library_list(summaries)}
      end
    end)
  end

  # ── diff_library ───────────────────────────────────────────────────────

  tool :diff_library,
       "Diff a library against its fork source, or compare two versions of the same library." do
    param(:library_id, :string, doc: "Forked library ID (diff against source)")
    param(:library_name, :string, doc: "Library name (version diff)")
    param(:version_a, :string, doc: "First version, e.g. '2026.01' or 'draft'")
    param(:version_b, :string, doc: "Second version")

    run(fn args, ctx ->
      if args[:library_name] && args[:version_a] && args[:version_b] do
        va = if args[:version_a] == "draft", do: nil, else: args[:version_a]
        vb = if args[:version_b] == "draft", do: nil, else: args[:version_b]

        case Library.diff_versions(ctx.organization_id, args[:library_name], va, vb) do
          {:ok, diff} -> {:ok, Jason.encode!(diff)}
          {:error, :not_found, msg} -> {:error, msg}
        end
      else
        case Library.diff_against_source(ctx.organization_id, args[:library_id]) do
          {:ok, diff} -> {:ok, Jason.encode!(diff)}
          {:error, :no_source, msg} -> {:error, msg}
        end
      end
    end)
  end

  # ── combine_libraries ──────────────────────────────────────────────────

  tool :combine_libraries,
       "Combine multiple libraries into one. Pass library UUIDs (NOT names) — " <>
         "look them up with manage_library(action: \"list\"). If a library is only " <>
         "in the workspace (library:<name> table) and not yet in the DB, save it " <>
         "first with save_framework(table: \"library:<name>\"). " <>
         "Without commit=true, returns a preview. With commit=true, creates the merged library." do
    param(:source_library_ids_json, :string,
      required: true,
      doc:
        ~s(JSON array of library UUIDs. Look up via manage_library. NOT names — names are rejected.)
    )

    param(:new_name, :string, required: true, doc: "Name for the combined library")
    param(:description, :string, doc: "Optional description")
    param(:commit, :boolean, doc: "false=preview (default), true=commit")
    param(:resolutions_json, :string, doc: ~s(JSON resolutions or "auto" to read from table))

    run(fn args, ctx ->
      raw = args[:source_library_ids_json] || "[]"

      with {:ok, refs} when is_list(refs) and refs != [] <- Jason.decode(raw),
           {:ok, ids} <- validate_uuids(refs) do
        if args[:commit] do
          do_combine_commit(ids, args, ctx)
        else
          do_combine_preview(ids, args, ctx)
        end
      else
        {:error, {:not_uuids, bad}} ->
          {:error,
           "These are not UUIDs: #{Enum.join(bad, ", ")}. " <>
             "combine_libraries requires saved-library UUIDs, not names. " <>
             "Run manage_library(action: \"list\") to see UUIDs of saved libraries. " <>
             "If a library is only in the workspace (e.g. \"library:CEO\" table) " <>
             "and not yet saved, call save_framework(table: \"library:<name>\") first."}

        _ ->
          {:error, "Provide a JSON array of at least 1 library UUID."}
      end
    end)
  end

  # Strict UUID validation. Returns {:ok, [uuid]} or {:error, {:not_uuids, [bad]}}.
  # No name fallback — names are ambiguous (across orgs, versions, workspace-vs-DB)
  # and lead to subtle bugs (typos, underscore↔space, template misroute).
  defp validate_uuids(refs) do
    {valid, invalid} =
      Enum.split_with(refs, fn ref ->
        is_binary(ref) and match?({:ok, _}, Ecto.UUID.cast(ref))
      end)

    case invalid do
      [] -> {:ok, valid}
      _ -> {:error, {:not_uuids, invalid}}
    end
  end

  defp do_combine_preview(ids, args, ctx) do
    case Library.combine_preview(ctx.organization_id, ids) do
      {:ok, %{conflicts: [], stats: stats} = preview} ->
        source_summary =
          Enum.map_join(preview.sources, " + ", fn s ->
            "#{s.name} (#{s.skill_count} skills)"
          end)

        {:ok,
         "Preview: #{source_summary} → '#{args[:new_name]}'. #{stats.total} skills, no conflicts."}

      {:ok, %{conflicts: conflicts, stats: stats} = preview} ->
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

        _ =
          DataTable.ensure_table(
            ctx.session_id,
            "combine_preview",
            DataTableSchemas.combine_preview_schema()
          )

        source_summary =
          Enum.map_join(preview.sources, " + ", fn s ->
            "#{s.name} (#{s.skill_count} skills)"
          end)

        %Rho.ToolResponse{
          text: "#{stats.conflicted} conflict(s), #{stats.clean} clean — #{source_summary}.",
          effects: [
            %Rho.Effect.OpenWorkspace{key: :data_table},
            %Rho.Effect.Table{
              table_name: "combine_preview",
              schema_key: :combine_conflicts,
              mode_label: "Combine: #{args[:new_name]}",
              rows: conflict_rows
            }
          ]
        }
    end
  end

  defp do_combine_commit(ids, args, ctx) do
    resolutions = resolve_resolutions(args[:resolutions_json], ctx.session_id)
    opts = maybe_opt([], :description, args[:description])

    unresolved =
      Enum.count(resolutions, fn r -> r["action"] in [nil, "", "unresolved"] end)

    if unresolved > 0 do
      {:error, "#{unresolved} conflict(s) still unresolved. Resolve before committing."}
    else
      case Library.combine_commit(ctx.organization_id, ids, args[:new_name], resolutions, opts) do
        {:ok, %{library: lib, skill_count: count}} ->
          {:ok, "Created '#{lib.name}' (#{lib.id}) — #{count} skills."}

        {:error, reason} ->
          {:error, "Combine commit failed: #{inspect(reason)}"}
      end
    end
  end

  # ── dedup_library ──────────────────────────────────────────────────────

  tool :dedup_library,
       "Open the duplicate-review panel for a saved library. Detects candidate-duplicate " <>
         "skill pairs (cosine similarity + slug/word heuristics), optionally clusters them " <>
         "by theme via an LLM digest, and writes them to the session's `dedup_preview` table. " <>
         "The user reviews each row in the data-table UI by setting `resolution` to merge_a, " <>
         "merge_b, or keep_both, then calls save_framework — which applies the picks and " <>
         "persists the cleaned library. Per-pair merge/dismiss are UI cell edits, not separate " <>
         "tool calls." do
    param(:library_id, :string,
      doc: "Library UUID or name. Omit to use the currently-active library tab."
    )

    param(:depth, :string,
      doc:
        "Detection depth: deep (default) — slug+word+cosine embedding; standard — slug+word only (faster, misses paraphrases)"
    )

    param(:summarize, :string,
      doc:
        "true (default) to add LLM cluster summary, false to skip and just emit raw cosine pairs"
    )

    run(fn args, ctx -> do_dedup_review(args, ctx) end)
  end

  defp do_dedup_review(args, ctx) do
    case resolve_dedup_library(args, ctx) do
      {:ok, lib} ->
        depth = if args[:depth] == "standard", do: :standard, else: :deep
        summarize? = args[:summarize] != "false"
        scope = Scope.from_context(ctx)

        case Workbench.write_dedup_preview(scope, lib.id,
               depth: depth,
               summarize: summarize?
             ) do
          {:ok, %{pair_count: 0, table_name: tbl}} ->
            %Rho.ToolResponse{
              text:
                "No duplicate candidates found in '#{lib.name}'. (Empty `#{tbl}` table opened.)",
              effects: build_dedup_effects(lib.name, tbl, false)
            }

          {:ok, %{pair_count: n, table_name: tbl, summary: summary}} ->
            text =
              "Loaded #{n} duplicate candidate(s) into the '#{tbl}' tab for '#{lib.name}'. " <>
                "Set each row's `resolution` (merge_a / merge_b / keep_both), then call " <>
                "save_framework to apply the picks and persist." <>
                if(is_binary(summary) and summary != "", do: "\n\n" <> summary, else: "")

            %Rho.ToolResponse{
              text: text,
              effects: build_dedup_effects(lib.name, tbl, true)
            }

          {:error, reason} ->
            {:error, "dedup_library failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_dedup_library(args, ctx) do
    case args[:library_id] do
      nil -> resolve_active_library(ctx)
      "" -> resolve_active_library(ctx)
      value when is_binary(value) -> resolve_library_input(value, ctx.organization_id)
      _ -> {:error, "library_id must be a string (UUID or library name)."}
    end
  end

  defp resolve_library_input("library:" <> name, org_id),
    do: resolve_library_input(name, org_id)

  defp resolve_library_input(value, org_id) do
    if uuid?(value) do
      case Library.get_library(org_id, value) do
        nil -> {:error, "Library not found: #{value}"}
        lib -> {:ok, lib}
      end
    else
      case Library.resolve_library(org_id, value) do
        nil -> {:error, "Library not found: '#{value}'. Pass a UUID or exact saved name."}
        lib -> {:ok, lib}
      end
    end
  end

  defp resolve_active_library(%{session_id: sid, organization_id: org_id})
       when is_binary(sid) do
    case DataTable.get_active_table(sid) do
      "library:" <> name ->
        case Library.resolve_library(org_id, name) do
          nil ->
            {:error,
             "Active library '#{name}' isn't saved yet. Call save_framework first, then dedup_library."}

          lib ->
            {:ok, lib}
        end

      _ ->
        {:error,
         "No active library tab. Pass library_id (UUID or saved name) or load a library first."}
    end
  end

  defp resolve_active_library(_),
    do: {:error, "No session context — pass library_id explicitly."}

  defp uuid?(s) when is_binary(s) do
    Regex.match?(
      ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
      s
    )
  end

  defp build_dedup_effects(lib_name, table_name, _has_pairs?) do
    [
      %Rho.Effect.OpenWorkspace{key: :data_table},
      %Rho.Effect.Table{
        table_name: table_name,
        schema_key: :dedup_preview,
        mode_label: "Duplicate review — #{lib_name}",
        rows: [],
        skip_write?: true
      }
    ]
  end

  # ── library_versions ───────────────────────────────────────────────────

  tool :library_versions,
       "Manage library versions. Actions: list (all published versions), set_default." do
    param(:action, :string, required: true, doc: "list | set_default")
    param(:library_name, :string, doc: "Library name (list)")
    param(:library_id, :string, doc: "Published library ID (set_default)")

    run(fn args, ctx ->
      case args[:action] do
        "list" -> do_list_versions(args, ctx)
        "set_default" -> do_set_default(args, ctx)
        other -> {:error, "Unknown action: #{other}. Use: list, set_default"}
      end
    end)
  end

  defp do_list_versions(args, ctx) do
    versions = Library.list_versions(ctx.organization_id, args[:library_name])
    draft = Library.get_draft(ctx.organization_id, args[:library_name])

    lines = ["\"#{args[:library_name]}\" versions:"]

    lines =
      if draft do
        lines ++ ["Draft: #{draft.id} (updated: #{draft.updated_at})"]
      else
        lines ++ ["Draft: none"]
      end

    lines =
      lines ++
        Enum.map(versions, fn v ->
          default = if v[:is_default], do: " *default*", else: ""
          "- v#{v[:version]} (#{v[:id]}) — #{v[:skill_count]} skills#{default}"
        end)

    {:ok, Enum.join(lines, "\n")}
  end

  defp do_set_default(args, ctx) do
    case Library.set_default_version(ctx.organization_id, args[:library_id]) do
      {:ok, lib} -> {:ok, "Default set: '#{lib.name}' v#{lib.version}."}
      {:error, :not_found} -> {:error, "Library not found"}
      {:error, :not_published, msg} -> {:error, msg}
      {:error, reason} -> {:error, "Failed: #{inspect(reason)}"}
    end
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
            description: MapAccess.get(data, :description, nil),
            skills:
              Enum.map(skills, fn skill ->
                %{
                  category: MapAccess.get(skill, :category),
                  cluster: MapAccess.get(skill, :cluster),
                  name: MapAccess.get(skill, :name),
                  description: MapAccess.get(skill, :description),
                  proficiency_levels:
                    Enum.map(MapAccess.get(skill, :proficiency_levels, []), fn lvl ->
                      %{
                        "level" => MapAccess.get(lvl, :level, 0),
                        "level_name" =>
                          MapAccess.get(lvl, :level_name, nil) || MapAccess.get(lvl, :name),
                        "level_description" =>
                          MapAccess.get(lvl, :level_description, nil) ||
                            MapAccess.get(lvl, :description)
                      }
                    end)
                }
              end),
            role_profiles:
              MapAccess.get(data, :role_profiles, [])
              |> Enum.map(fn rp ->
                %{
                  name: MapAccess.get(rp, :name, nil),
                  role_family: MapAccess.get(rp, :role_family, nil),
                  seniority_level: MapAccess.get(rp, :seniority_level, nil),
                  seniority_label: MapAccess.get(rp, :seniority_label, nil),
                  purpose: MapAccess.get(rp, :purpose, nil),
                  skills:
                    Enum.map(MapAccess.get(rp, :skills, []), fn rs ->
                      %{
                        skill_name: MapAccess.get(rs, :skill_name, nil),
                        min_expected_level: MapAccess.get(rs, :min_expected_level, 1),
                        required: Map.get(rs, "required", Map.get(rs, :required, true))
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

  # ── Formatters ──────────────────────────────────────────────────────────

  defp format_search_results([]), do: "No results."

  defp format_search_results(results) do
    results
    |> Enum.map_join("\n", fn r ->
      name = MapAccess.get(r, :name)
      cat = MapAccess.get(r, :category)
      lib = MapAccess.get(r, :library_name, "?")
      "- #{name} [#{cat}] in \"#{lib}\""
    end)
    |> then(&"Found #{length(results)} results:\n#{&1}")
  end

  # Large libraries (e.g. ESCO with ~14k skills) blow the LLM context if
  # we dump every row. When no category was specified and the library
  # exceeds @browse_full_dump_max, return a category index instead and
  # tell the agent to drill down.
  @browse_full_dump_max 500

  defp browse_library_or_index(lib, opts, args) do
    has_category? = match?(c when is_binary(c) and c != "", args[:category])
    count = Library.skill_count(lib.id)

    if not has_category? and count > @browse_full_dump_max do
      index = Library.list_skill_index(lib.id, opts)
      {:ok, format_browse_index(lib.name, count, index)}
    else
      skills = Library.browse_library(lib.id, opts)
      {:ok, format_browse_results(lib.name, skills)}
    end
  end

  defp format_browse_index(lib_name, total, index) do
    by_category =
      index
      |> Enum.group_by(& &1.category)
      |> Enum.sort_by(&elem(&1, 0))

    lines =
      Enum.map(by_category, fn {category, rows} ->
        cat_total = Enum.reduce(rows, 0, fn r, acc -> acc + r.count end)
        clusters = rows |> Enum.map(& &1.cluster) |> Enum.reject(&is_nil/1)

        cluster_hint =
          if clusters == [], do: "", else: " — clusters: #{Enum.join(clusters, ", ")}"

        "  - #{category} (#{cat_total} skills)#{cluster_hint}"
      end)

    """
    "#{lib_name}" — #{total} skills across #{length(by_category)} categories. \
    Too many to list. Call browse_library again with `category: "<name>"` to list \
    a category, or use find_skill / find_similar_skills for keyword and semantic \
    search.

    #{Enum.join(lines, "\n")}
    """
  end

  defp format_browse_results(lib_name, []), do: "Library '#{lib_name}' has no skills."

  defp format_browse_results(lib_name, skills) do
    grouped =
      skills
      |> Enum.group_by(fn s -> MapAccess.get(s, :category, "Uncategorized") end)
      |> Enum.sort_by(&elem(&1, 0))

    sections =
      Enum.map(grouped, fn {category, cat_skills} ->
        lines =
          Enum.map(cat_skills, fn s ->
            name = MapAccess.get(s, :name)
            levels = MapAccess.get(s, :proficiency_levels, []) |> length()
            status = MapAccess.get(s, :status, "draft")
            "  - #{name} (#{levels} levels, #{status})"
          end)

        "## #{category} (#{length(cat_skills)})\n#{Enum.join(lines, "\n")}"
      end)

    "\"#{lib_name}\" — #{length(skills)} skills\n\n#{Enum.join(sections, "\n\n")}"
  end

  defp format_library_list([]), do: "No libraries found."

  defp format_library_list(libraries) do
    lines =
      Enum.map(libraries, fn lib ->
        version =
          cond do
            lib[:version] -> "v#{lib.version}"
            lib[:immutable] -> "immutable"
            true -> "draft"
          end

        cats = Enum.map_join(lib.categories, ", ", & &1.category)
        "- **#{lib.name}** (id: #{lib.id}, #{version}, #{lib.skill_count} skills) — #{cats}"
      end)

    "#{length(libraries)} libraries:\n#{Enum.join(lines, "\n")}"
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  @doc false
  defdelegate library_table_name(lib_name), to: Editor, as: :table_name

  defp not_found_with_hints(org_id, name) do
    if name && Roles.get_role_profile_by_name(org_id, name) do
      {:error,
       "'#{name}' is a role profile, not a library. " <>
         "Use manage_role(action: \"load\", name: \"#{name}\") instead."}
    else
      available =
        Library.list_libraries(org_id)
        |> Enum.map_join(", ", & &1.name)

      if available == "" do
        {:error, "No libraries found. Use manage_library(action: \"create\") to create one."}
      else
        {:error, "Library not found. Available: #{available}"}
      end
    end
  end

  defp template_key?(nil), do: false

  defp template_key?(name) when is_binary(name) do
    # Only treat as a template key if a matching template file actually exists.
    # Earlier heuristic (underscore + no space) misclassified user-named
    # libraries like "CEO_Merged", "CEO_v2", routing them to the template
    # loader and erroring with "Template 'X' not found".
    templates_dir = Application.app_dir(:rho_frameworks, "priv/templates")
    File.exists?(Path.join(templates_dir, "#{name}.json"))
  end

  defp template_key?(_), do: false

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, _key, ""), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)

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
          nil -> {:error, "Library not found for library_name=#{inspect(name)}."}
          lib -> {:ok, lib}
        end

      true ->
        {:error, "Provide library_id or library_name, or use query for cross-library search."}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value

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
      {:ok, rows} -> Enum.map(rows, &parse_resolution_row/1)
      _ -> []
    end
  end

  defp parse_resolution_row(row) do
    {action, keep} =
      case get_in_row(row, :resolution) do
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
  end

  defp get_in_row(row, key) when is_atom(key) do
    Map.get(row, key) || Map.get(row, Atom.to_string(key))
  end
end