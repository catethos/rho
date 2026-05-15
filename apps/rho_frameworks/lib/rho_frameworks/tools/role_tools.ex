defmodule RhoFrameworks.Tools.RoleTools do
  @moduledoc """
  Consolidated role tools — 3 tools covering all role profile operations.
  """

  use Rho.Tool

  alias RhoFrameworks.Roles
  alias RhoFrameworks.GapAnalysis
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.Scope
  alias RhoFrameworks.Workbench
  alias Rho.Stdlib.DataTable

  # ── manage_role ────────────────────────────────────────────────────────

  tool :manage_role,
       "Role profile CRUD. Actions: list, view, load, save, start_draft, clone." do
    param(:action, :string,
      required: true,
      doc: "list | view | load | save | start_draft | clone"
    )

    param(:name, :string)
    param(:role_profile_id, :string)
    param(:role_family, :string)
    param(:seniority_level, :integer, doc: "1-5")
    param(:seniority_label, :string)
    param(:description, :string)
    param(:purpose, :string)
    param(:resolve_library_id, :string)
    param(:role_profile_ids_json, :string, doc: "JSON array of IDs")
    param(:mode_label, :string)

    run(fn args, ctx ->
      case args[:action] do
        "list" ->
          do_list_roles(args, ctx)

        "view" ->
          do_view_role(args, ctx)

        "load" ->
          do_load_role(args, ctx)

        "save" ->
          do_save_role(args, ctx)

        "start_draft" ->
          do_start_draft(args, ctx)

        "clone" ->
          do_clone_role(args, ctx)

        other ->
          {:error, "Unknown action: #{other}. Use: list, view, load, save, start_draft, clone"}
      end
    end)
  end

  defp do_list_roles(args, ctx) do
    opts = maybe_opt([], :role_family, args[:role_family])
    profiles = Roles.list_role_profiles(ctx.organization_id, opts)

    result =
      Enum.map_join(profiles, "\n", fn rp ->
        family = if rp.role_family, do: " [#{rp.role_family}]", else: ""
        level = if rp.seniority_label, do: " #{rp.seniority_label}", else: ""
        "- #{rp.name} (#{rp.id}) —#{family}#{level} #{rp.skill_count} skills"
      end)

    {:ok, result}
  end

  defp do_view_role(args, ctx) do
    result =
      cond do
        args[:role_profile_id] ->
          load_role_by_id(ctx.organization_id, args[:role_profile_id])

        args[:name] ->
          Roles.load_role_profile(ctx.organization_id, args[:name])

        true ->
          {:error, :not_found}
      end

    case result do
      {:error, :not_found} ->
        {:error, "Role profile not found. Provide name or role_profile_id."}

      {:ok, %{role_profile: rp, rows: rows}} ->
        {:ok, format_role_view(rp, rows)}
    end
  end

  defp do_load_role(args, ctx) do
    result =
      cond do
        args[:role_profile_id] ->
          load_role_by_id(ctx.organization_id, args[:role_profile_id])

        args[:name] ->
          Roles.load_role_profile(ctx.organization_id, args[:name])

        true ->
          {:error, :not_found}
      end

    case result do
      {:error, :not_found} ->
        identifier = args[:role_profile_id] || args[:name] || "?"

        {:error,
         "Role profile '#{identifier}' not found for org #{ctx.organization_id}. Use manage_role(action: \"list\") to see available roles."}

      {:ok, %{role_profile: rp, rows: rows}} ->
        scope = Scope.from_context(ctx)

        with :ok <-
               DataTable.ensure_table(
                 ctx.session_id,
                 "role_profile",
                 DataTableSchemas.role_profile_schema()
               ),
             {:ok, _} <- Workbench.replace_rows(scope, rows, table: "role_profile") do
          %Rho.ToolResponse{
            text: "'#{rp.name}' — #{length(rows)} skills, table: 'role_profile'.",
            effects: [
              %Rho.Effect.OpenWorkspace{key: :data_table},
              %Rho.Effect.Table{
                table_name: "role_profile",
                schema_key: :role_profile,
                mode_label: "Role Profile — #{rp.name}",
                metadata:
                  role_profile_metadata(rp.name, :role_profile_edit,
                    role_profile_id: rp.id,
                    source_label: "Loaded saved role profile",
                    persisted?: true,
                    dirty?: false
                  ),
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

  defp load_role_by_id(org_id, id) do
    rp = Roles.get_visible_role_profile_with_skills!(org_id, id)

    rows =
      Enum.map(rp.role_skills, fn rs ->
        %{
          category: rs.skill.category,
          cluster: rs.skill.cluster,
          skill_name: rs.skill.name,
          required_level: rs.min_expected_level,
          required: rs.required
        }
      end)

    {:ok, %{role_profile: rp, rows: rows}}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp do_save_role(args, ctx) do
    name = args[:name]

    if is_nil(name) or name == "" do
      {:error, "Role profile name is required"}
    else
      case DataTable.get_rows(ctx.session_id, table: "role_profile") do
        {:error, :not_running} ->
          {:error, "No 'role_profile' table active — load or start a draft first."}

        [] ->
          {:error, "The 'role_profile' table is empty — add skills first"}

        rows when is_list(rows) ->
          attrs = %{name: name}
          attrs = maybe_put(attrs, :role_family, args[:role_family])
          attrs = maybe_put(attrs, :seniority_level, args[:seniority_level])
          attrs = maybe_put(attrs, :seniority_label, args[:seniority_label])
          attrs = maybe_put(attrs, :description, args[:description])
          attrs = maybe_put(attrs, :purpose, args[:purpose])

          opts = maybe_opt([], :resolve_library_id, args[:resolve_library_id])

          case Roles.save_role_profile(ctx.organization_id, attrs, rows, opts) do
            {:ok, %{role_profile: _rp, role_skills: skill_count}} ->
              {:ok, "Saved '#{name}' — #{skill_count} skill(s)."}

            {:error, step, changeset, _} ->
              {:error, "Save failed at #{step}: #{inspect(changeset)}"}
          end
      end
    end
  end

  defp do_start_draft(args, ctx) do
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
              metadata:
                role_profile_metadata(args[:name] || "New Role", :role_profile_edit,
                  title: label,
                  dirty?: true
                ),
              rows: []
            }
          ]
        }

      {:error, reason} ->
        {:error, "Failed to prepare table: #{inspect(reason)}"}
    end
  end

  defp do_clone_role(args, ctx) do
    raw = args[:role_profile_ids_json] || "[]"

    case Jason.decode(raw) do
      {:ok, ids} when is_list(ids) and ids != [] ->
        rows = Roles.clone_role_skills(ctx.organization_id, ids)
        scope = Scope.from_context(ctx)

        with :ok <-
               DataTable.ensure_table(
                 ctx.session_id,
                 "role_profile",
                 DataTableSchemas.role_profile_schema()
               ),
             {:ok, _} <- Workbench.replace_rows(scope, rows, table: "role_profile") do
          %Rho.ToolResponse{
            text: "Cloned #{length(rows)} skills from #{length(ids)} role(s).",
            effects: [
              %Rho.Effect.OpenWorkspace{key: :data_table},
              %Rho.Effect.Table{
                table_name: "role_profile",
                schema_key: :role_profile,
                mode_label: "New Role Profile (cloned)",
                metadata:
                  role_profile_metadata("Cloned Role", :role_profile_edit,
                    title: "Cloned Role Requirements",
                    source_role_profile_ids: ids,
                    source_label: "Cloned from #{length(ids)} role(s)",
                    dirty?: true
                  ),
                rows: [],
                skip_write?: true
              }
            ]
          }
        else
          {:error, reason} -> {:error, "Failed to prepare table: #{inspect(reason)}"}
        end

      _ ->
        {:error, "Provide a JSON array of at least 1 role profile ID."}
    end
  end

  # ── analyze_role ───────────────────────────────────────────────────────

  tool :analyze_role,
       "Role analysis. Actions: find_similar, gap_analysis, check_currency, career_ladder." do
    param(:action, :string,
      required: true,
      doc: "find_similar | gap_analysis | career_ladder"
    )

    param(:query, :string, doc: "Search term (find_similar) — single role name")

    param(:queries_json, :string,
      doc:
        "JSON array of role names for find_similar — preferred when looking for several roles at once " <>
          "(e.g. [\"Risk Analyst\", \"Compliance Officer\"]). Returns results grouped per query so one " <>
          "call covers a whole multi-role search instead of a sequence of `query`-only calls."
    )

    param(:role_profile_id, :string, doc: "Role profile ID (gap_analysis)")
    param(:snapshot_json, :string, doc: "JSON skill snapshot (gap_analysis)")
    param(:role_family, :string, doc: "e.g. Engineering (career_ladder)")

    param(:library_id, :string,
      doc: "Library UUID — restrict find_similar to roles with skills from this library"
    )

    run(fn args, ctx ->
      case args[:action] do
        "find_similar" ->
          do_find_similar(args, ctx)

        "gap_analysis" ->
          do_gap_analysis(args)

        "career_ladder" ->
          do_career_ladder(args, ctx)

        other ->
          {:error, "Unknown action: #{other}. Use: find_similar, gap_analysis, career_ladder"}
      end
    end)
  end

  defp do_find_similar(args, ctx) do
    opts = build_find_similar_opts(args)

    case parse_find_similar_queries(args) do
      {:ok, queries} ->
        groups =
          Enum.map(queries, fn q ->
            {q, Roles.find_similar_roles(ctx.organization_id, q, opts)}
          end)

        emit_role_candidates(groups, ctx)

      {:error, msg} ->
        {:error, msg}
    end
  end

  # Write candidates to the `role_candidates` table for UI selection,
  # then return a short text summary + Effect.Table to open the tab.
  # User checks the rows they want and the next tool call (e.g.
  # `seed_framework_from_roles(from_selected_candidates: true)` or
  # `manage_role(action: "clone")`) reads the picks.
  defp emit_role_candidates(groups, ctx) do
    scope = Scope.from_context(ctx)
    nonempty? = Enum.any?(groups, fn {_q, rs} -> rs != [] end)

    case Workbench.write_role_candidates(scope, groups) do
      {:ok, %{table_name: tbl, total: total, per_query: per_query}} when nonempty? ->
        text =
          "Loaded #{total} candidate role(s) into the '#{tbl}' tab:\n" <>
            Enum.map_join(per_query, "\n", fn %{query: q, count: n} ->
              "- '#{q}': #{n} match(es)"
            end) <>
            "\n\nReview the rows and check the ones you want. Then say 'seed' " <>
            "(to combine into a new framework) or 'clone' (to start a new role profile)."

        %Rho.ToolResponse{
          text: text,
          effects: [
            %Rho.Effect.OpenWorkspace{key: :data_table},
            %Rho.Effect.Table{
              table_name: tbl,
              schema_key: :role_candidates,
              mode_label: "Candidate Roles",
              metadata: role_candidates_metadata(tbl, per_query, total, args_from_groups(groups)),
              rows: [],
              skip_write?: true
            }
          ]
        }

      {:ok, _} ->
        # All queries returned zero matches.
        per_query =
          Enum.map_join(groups, "\n", fn {q, _rs} -> "- '#{q}': 0 matches" end)

        {:ok,
         "No similar role profiles found:\n#{per_query}\n\nTry a broader query, or remove the library_id filter to search org-wide."}

      {:error, reason} ->
        {:error, "find_similar failed to populate the candidates table: #{inspect(reason)}"}
    end
  end

  defp build_find_similar_opts(args) do
    case args[:library_id] do
      id when is_binary(id) and id != "" -> [library_id: id]
      _ -> []
    end
  end

  # Multi-query (queries_json) wins when both are provided — multi-query is
  # what the agent should reach for in framework-composition flows.
  defp parse_find_similar_queries(args) do
    case decode_queries_json(args[:queries_json]) do
      {:ok, _} = ok -> ok
      :no_input -> single_query_or_error(args[:query])
      {:error, _} = err -> err
    end
  end

  defp decode_queries_json(nil), do: :no_input
  defp decode_queries_json(""), do: :no_input

  defp decode_queries_json(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, list} when is_list(list) and list != [] ->
        cleaned = Enum.map(list, &maybe_trim/1)

        if Enum.all?(cleaned, &(is_binary(&1) and &1 != "")) do
          {:ok, cleaned}
        else
          {:error, "queries_json entries must all be non-empty role-name strings."}
        end

      {:ok, []} ->
        {:error, "queries_json must be a non-empty JSON array."}

      {:ok, _} ->
        {:error, "queries_json must be a JSON array of strings."}

      {:error, _} ->
        {:error, "queries_json is not valid JSON."}
    end
  end

  defp decode_queries_json(_), do: :no_input

  defp single_query_or_error(q) when is_binary(q) do
    case String.trim(q) do
      "" -> {:error, "Provide a `query` string or a `queries_json` array."}
      trimmed -> {:ok, [trimmed]}
    end
  end

  defp single_query_or_error(_),
    do: {:error, "Provide a `query` string or a `queries_json` array."}

  defp maybe_trim(s) when is_binary(s), do: String.trim(s)
  defp maybe_trim(s), do: s

  defp do_gap_analysis(args) do
    raw = args[:snapshot_json] || "{}"

    case Jason.decode(raw) do
      {:ok, snapshots} when is_map(snapshots) ->
        people =
          Enum.map(snapshots, fn {person_id, skills} ->
            {person_id, Map.new(skills, fn {k, v} -> {k, v} end)}
          end)

        result =
          if match?([_], people) do
            {_id, snapshot} = hd(people)
            GapAnalysis.individual_gap(snapshot, args[:role_profile_id])
          else
            GapAnalysis.team_gap(people, args[:role_profile_id])
          end

        # Gap analysis is structured data the agent needs to reason over — keep JSON
        {:ok, Jason.encode!(result)}

      _ ->
        {:error, "Invalid JSON. Provide {person_id: {skill_id: level}}."}
    end
  end

  defp do_career_ladder(args, ctx) do
    profiles = Roles.career_ladder(ctx.organization_id, args[:role_family])

    if profiles == [] do
      {:ok, "No roles found for family '#{args[:role_family]}'."}
    else
      lines =
        Enum.map(profiles, fn p ->
          new = MapSet.to_list(p.new_skills)
          dropped = MapSet.to_list(p.dropped_skills)
          count = MapSet.size(p.skill_set)

          new_str =
            if new != [],
              do: " | +#{length(new)}: #{Enum.join(Enum.take(new, 5), ", ")}",
              else: ""

          drop_str =
            if dropped != [],
              do: " | -#{length(dropped)}: #{Enum.join(Enum.take(dropped, 5), ", ")}",
              else: ""

          "#{p.seniority_level}. #{p.name} (#{p.seniority_label}) — #{count} skills#{new_str}#{drop_str}"
        end)

      {:ok, "Career Ladder: #{args[:role_family]}\n#{Enum.join(lines, "\n")}"}
    end
  end

  # ── org_view ───────────────────────────────────────────────────────────

  tool :org_view,
       "Cross-role summary: shared vs unique skills, role families, per-role counts." do
    run(fn _args, ctx ->
      view = Roles.org_view(ctx.organization_id)
      {:ok, format_org_view(view)}
    end)
  end

  # ── Formatters ─────────────────────────────────────────────────────────

  defp format_role_view(rp, rows) do
    family = if rp.role_family, do: " [#{rp.role_family}]", else: ""
    label = if rp.seniority_label, do: " #{rp.seniority_label}", else: ""

    header = "\"#{rp.name}\"#{family}#{label}\nID: #{rp.id}"

    grouped =
      rows
      |> Enum.group_by(& &1[:category])
      |> Enum.sort_by(&elem(&1, 0))

    sections =
      Enum.map(grouped, fn {cat, cat_rows} ->
        lines =
          Enum.map(cat_rows, fn r ->
            req = if r[:required], do: "required", else: "optional"
            "  - #{r[:skill_name]}: level #{r[:required_level]} (#{req})"
          end)

        "## #{cat} (#{length(cat_rows)})\n#{Enum.join(lines, "\n")}"
      end)

    "#{header}\n\nSkills (#{length(rows)}):\n#{Enum.join(sections, "\n\n")}"
  end

  defp format_org_view(view) do
    role_count = Map.get(view, :role_count, 0)
    shared = Map.get(view, :shared_skills, [])
    shared_count = Map.get(view, :shared_count, length(shared))
    families = Map.get(view, :role_families, %{})
    unique = Map.get(view, :unique_per_role, %{})

    lines = ["Org Overview: #{role_count} roles, shared skills: #{shared_count}"]

    lines =
      if shared != [] do
        lines ++
          [
            "Shared: #{Enum.join(Enum.take(shared, 10), ", ")}#{if length(shared) > 10, do: "...", else: ""}"
          ]
      else
        lines
      end

    family_lines =
      Enum.map(families, fn {family, roles} ->
        "  #{family}: #{Enum.join(roles, ", ")}"
      end)

    lines = lines ++ ["Role families:"] ++ family_lines

    unique_lines =
      Enum.map(unique, fn {role, skills} ->
        "  #{role}: #{Enum.join(Enum.take(skills, 5), ", ")} (#{length(skills)} unique)"
      end)

    lines = if unique_lines != [], do: lines ++ ["Unique per role:"] ++ unique_lines, else: lines

    Enum.join(lines, "\n")
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, _key, ""), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp role_profile_metadata(name, workflow, opts) do
    title = Keyword.get(opts, :title) || "#{name} Role Requirements"

    %{
      workflow: workflow,
      artifact_kind: :role_profile,
      title: title,
      role_name: name,
      output_table: "role_profile",
      dirty?: Keyword.get(opts, :dirty?, true),
      persisted?: Keyword.get(opts, :persisted?, false)
    }
    |> maybe_put(:role_profile_id, Keyword.get(opts, :role_profile_id))
    |> maybe_put(:source_label, Keyword.get(opts, :source_label))
    |> maybe_put(:source_role_profile_ids, Keyword.get(opts, :source_role_profile_ids))
  end

  defp role_candidates_metadata(table_name, per_query, total, queries) do
    %{
      workflow: :role_search,
      artifact_kind: :role_candidates,
      title: "Candidate Roles",
      output_table: table_name,
      source_role_names: queries,
      source_label: Enum.join(queries, ", "),
      candidate_count: total,
      query_count: length(per_query),
      ui_intent: %{
        surface: :role_candidate_picker,
        artifact_table: table_name,
        allowed_actions: [:seed_framework_from_selected, :clone_selected_role],
        props: %{queries: queries}
      }
    }
  end

  defp args_from_groups(groups) do
    Enum.map(groups, fn {query, _roles} -> query end)
  end
end
