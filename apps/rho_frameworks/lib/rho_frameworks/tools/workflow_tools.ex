defmodule RhoFrameworks.Tools.WorkflowTools do
  @moduledoc """
  ReqLLM tool wrappers around `RhoFrameworks.UseCases.*`.

  These tools let the chat agent invoke the same workflow units the
  wizard's `RhoFrameworks.FlowRunner` runs. Each wrapper builds a typed
  input map from the LLM-supplied args, delegates to the UseCase, and
  formats the result into the chat-friendly text/error shape the agent
  expects.

  Adding a new UseCase to the chat surface is one new `tool/3` block
  here — the UseCase itself doesn't need to change.
  """

  use Rho.Tool

  alias Rho.Events
  alias Rho.Stdlib.DataTable
  alias Rho.Stdlib.EffectDispatcher
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.Roles
  alias RhoFrameworks.Scope

  alias RhoFrameworks.UseCases.{
    GenerateFrameworkSkeletons,
    GenerateProficiency,
    ExtractFromJD,
    ImportFromUpload,
    LoadSimilarRoles,
    PickTemplate,
    SaveFramework
  }

  @use_case_tool_names %{
    LoadSimilarRoles => "load_similar_roles",
    GenerateFrameworkSkeletons => "generate_framework_skeletons",
    GenerateProficiency => "generate_proficiency",
    SaveFramework => "save_framework",
    ImportFromUpload => "import_library_from_upload",
    ExtractFromJD => "extract_role_from_jd"
  }

  @doc """
  Returns the chat-side tool def for a UseCase module, or `nil` if the
  UseCase has no chat surface (e.g. `PickTemplate`, `ResearchDomain`).

  Used by the wizard's `<.step_chat />` component to constrain the
  per-step agent's tool list to *just* the current node's UseCase plus
  `clarify`.
  """
  @spec tool_for_use_case(module()) :: map() | nil
  def tool_for_use_case(use_case) when is_atom(use_case) do
    case Map.fetch(@use_case_tool_names, use_case) do
      {:ok, name} ->
        Enum.find(__tools__(), fn t -> t.tool.name == name end)

      :error ->
        nil
    end
  end

  @doc """
  Returns the `clarify` tool def. Pair with `tool_for_use_case/1` to
  build the step-chat agent's tool list.
  """
  @spec clarify_tool() :: map()
  def clarify_tool do
    Enum.find(__tools__(), fn t -> t.tool.name == "clarify" end)
  end

  # ── load_similar_roles ─────────────────────────────────────────────────

  tool :load_similar_roles,
       "Find existing role profiles similar to the framework being built. " <>
         "Pass intake-style fields; returns the top matches." do
    param(:name, :string, doc: "Framework name")
    param(:description, :string)
    param(:domain, :string)
    param(:target_roles, :string, doc: "Comma-separated role list")
    param(:limit, :integer, doc: "default: 5")

    run(fn args, ctx ->
      scope = Scope.from_context(ctx)

      input =
        %{
          name: args[:name],
          description: args[:description],
          domain: args[:domain],
          target_roles: args[:target_roles]
        }
        |> maybe_put(:limit, args[:limit])

      case LoadSimilarRoles.run(input, scope) do
        {:ok, %{matches: [], skip_reason: reason}} ->
          {:ok, "No similar roles found. #{reason}"}

        {:ok, %{matches: matches}} ->
          {:ok, format_matches(matches)}
      end
    end)
  end

  # ── generate_framework_skeletons ───────────────────────────────────────

  tool :generate_framework_skeletons,
       "Generate the skill skeletons for a new framework via a single streaming BAML call. " <>
         "Synchronous (typically 3–5s); rows stream into the session's library:<name> table " <>
         "as partials arrive." do
    param(:name, :string, required: true, doc: "Framework name")
    param(:description, :string, required: true)
    param(:domain, :string)
    param(:target_roles, :string)
    param(:skill_count, :integer, doc: "default: 12")
    param(:similar_role_skills, :string, doc: "Optional seed context block")
    param(:research, :string, doc: "Optional formatted research bullet list")

    run(fn args, ctx ->
      scope = Scope.from_context(ctx)

      input = %{
        name: args[:name],
        description: args[:description],
        domain: args[:domain],
        target_roles: args[:target_roles],
        skill_count: args[:skill_count],
        similar_role_skills: args[:similar_role_skills],
        research: args[:research],
        # Threaded through so the use case can keep the agent's turn
        # watchdog alive during a long BAML stream. Scope intentionally
        # excludes agent_id (domain-only), so we pass it via input.
        agent_id: ctx.agent_id
      }

      # Pre-flight: ensure the library table exists and switch the LV's
      # active data-table tab to it BEFORE streaming begins. Without this,
      # rows stream in but the user is still looking at the "main" tab.
      maybe_open_library_tab(ctx, args[:name])

      case GenerateFrameworkSkeletons.run(input, scope) do
        {:ok, %{added: added, table_name: tbl}} ->
          %Rho.ToolResponse{
            text: "Generated #{length(added)} skill(s) into '#{tbl}'.",
            effects: [
              %Rho.Effect.OpenWorkspace{key: :data_table},
              %Rho.Effect.Table{
                table_name: tbl,
                schema_key: :skill_library,
                mode_label: "Skill Library — #{args[:name]}",
                metadata:
                  library_metadata(args[:name], tbl, :create_framework,
                    generated?: true,
                    source_label: args[:description]
                  ),
                rows: [],
                skip_write?: true
              }
            ]
          }

        {:error, :missing_name} ->
          {:error, "name is required."}

        {:error, :missing_description} ->
          {:error, "description is required."}

        {:error, reason} ->
          {:error, "generate_framework_skeletons failed: #{inspect(reason)}"}
      end
    end)
  end

  defp maybe_open_library_tab(_ctx, nil), do: :ok
  defp maybe_open_library_tab(_ctx, ""), do: :ok

  defp maybe_open_library_tab(ctx, name) when is_binary(name) do
    session_id = ctx.session_id
    agent_id = ctx.agent_id

    if is_binary(session_id) do
      table_name = Editor.table_name(name)
      _ = DataTable.ensure_started(session_id)
      _ = DataTable.ensure_table(session_id, table_name, DataTableSchemas.library_schema())

      EffectDispatcher.dispatch_all(
        [
          %Rho.Effect.OpenWorkspace{key: :data_table},
          %Rho.Effect.Table{
            table_name: table_name,
            schema_key: :skill_library,
            mode_label: "Skill Library — #{name}",
            metadata:
              library_metadata(name, table_name, :create_framework,
                generated?: true,
                source_label: "Generating framework skeleton"
              ),
            rows: [],
            skip_write?: true
          }
        ],
        %{session_id: session_id, agent_id: agent_id}
      )
    end

    :ok
  end

  # ── generate_proficiency ───────────────────────────────────────────────

  tool :generate_proficiency,
       "Spawn one proficiency-writer agent per category for the given library table. " <>
         "Reads skeleton rows from the named table and fans out asynchronously." do
    param(:table_name, :string, required: true, doc: "Library table name (e.g. library:Eng)")
    param(:levels, :integer, doc: "Levels to generate (default 5)")

    run(fn args, ctx ->
      scope = Scope.from_context(ctx)

      input = %{
        table_name: args[:table_name],
        levels: args[:levels] || 5,
        # Threaded through so the use case's `:task_requested`,
        # `:task_completed`, and `:structured_partial` events attribute
        # to the chat agent's tab — without this they route to a phantom
        # agent (session_id) and never appear in the chat thread.
        agent_id: ctx.agent_id
      }

      case GenerateProficiency.run(input, scope) do
        {:async, %{workers: workers}} ->
          # Block the chat agent's tool call until every fan-out writer
          # finishes. The wait loop tickles the agent's watchdog on every
          # event, so the 60s inactivity limit doesn't fire even when the
          # writers take ~30–60s to complete. The wizard/flow path keeps
          # the use case's async semantics by calling `.run/2` directly.
          worker_ids = Enum.map(workers, & &1.agent_id)

          summary =
            wait_for_writers(ctx.session_id, ctx.agent_id, worker_ids,
              timeout: @proficiency_wait_timeout_ms
            )

          format_proficiency_summary(args[:table_name], length(workers), summary)

        {:error, :missing_table_name} ->
          {:error, "table_name is required."}

        {:error, :empty_rows} ->
          {:error, "No rows in '#{args[:table_name]}'. Generate skeletons first."}

        {:error, reason} ->
          {:error, "generate_proficiency failed: #{inspect(reason)}"}
      end
    end)
  end

  @proficiency_wait_timeout_ms 5 * 60 * 1_000

  defp format_proficiency_summary(table_name, total, %{ok: ok, error: error, pending: 0}) do
    base = "Proficiency complete for '#{table_name}': #{ok}/#{total} categories OK"

    if error > 0 do
      {:ok, base <> ", #{error} failed."}
    else
      {:ok, base <> "."}
    end
  end

  defp format_proficiency_summary(table_name, total, %{
         ok: ok,
         error: error,
         pending: pending
       }) do
    {:error,
     "Proficiency wait timed out for '#{table_name}': #{ok}/#{total} OK, " <>
       "#{error} failed, #{pending} still running."}
  end

  # Waits until every spawned fan-out writer has fired :task_completed
  # for one of `worker_ids`. Side-effects:
  #   - subscribes to the session topic for the duration of the wait
  #   - tickles the agent's `last_activity_at` on every received event
  #     (otherwise the runner's 60s watchdog kills the chat agent)
  defp wait_for_writers(session_id, agent_id, worker_ids, opts) do
    timeout = Keyword.get(opts, :timeout, 5 * 60 * 1_000)
    pending = MapSet.new(worker_ids)

    Rho.Events.subscribe(session_id)

    try do
      do_wait(pending, agent_id, %{ok: 0, error: 0}, timeout)
    after
      Rho.Events.unsubscribe(session_id)
    end
  end

  defp do_wait(pending, _agent_id, counts, _timeout) when pending == %MapSet{} do
    Map.put(counts, :pending, 0)
  end

  defp do_wait(pending, agent_id, counts, timeout) do
    Rho.Agent.Worker.touch_activity(agent_id)

    receive do
      %Rho.Events.Event{
        kind: :task_completed,
        data: %{worker_agent_id: id, status: status}
      } ->
        if MapSet.member?(pending, id) do
          do_wait(MapSet.delete(pending, id), agent_id, bump(counts, status), timeout)
        else
          do_wait(pending, agent_id, counts, timeout)
        end

      %Rho.Events.Event{} ->
        do_wait(pending, agent_id, counts, timeout)
    after
      timeout ->
        Map.put(counts, :pending, MapSet.size(pending))
    end
  end

  defp bump(counts, :ok), do: %{counts | ok: counts.ok + 1}
  defp bump(counts, :error), do: %{counts | error: counts.error + 1}
  defp bump(counts, _), do: counts

  # ── save_framework ─────────────────────────────────────────────────────

  tool :save_framework,
       "Persist the framework currently in the session's library table to the database. " <>
         "If library_id is omitted, saves to (or creates) the org's default library." do
    param(:library_id, :string)
    param(:table, :string, doc: "Library table name override (default: derived from library)")

    run(fn args, ctx ->
      scope = Scope.from_context(ctx)
      input = %{library_id: args[:library_id], table_name: args[:table]}

      case SaveFramework.run(input, scope) do
        {:ok, %{saved_count: count, library_name: name, draft_library_id: draft_id} = result} ->
          msg = "Saved #{count} skill(s) to '#{name}'."
          msg = if draft_id, do: msg <> " Draft created (#{draft_id}).", else: msg
          msg = msg <> dedup_suffix(Map.get(result, :dedup_applied))
          {:ok, msg}

        {:error, :not_found} ->
          {:error, "Library not found."}

        {:error, {:not_running, tbl}} ->
          {:error, "No '#{tbl}' table — load a library first."}

        {:error, {:empty_table, tbl}} ->
          {:error, "The '#{tbl}' table is empty."}

        {:error, {:save_failed, step, cs}} ->
          {:error, "Save failed at #{step}: #{inspect(cs)}"}

        {:error, reason} ->
          {:error, "save_framework failed: #{inspect(reason)}"}
      end
    end)
  end

  defp dedup_suffix(nil), do: ""

  defp dedup_suffix(%{merged: 0, dismissed: 0, errors: []}), do: ""

  defp dedup_suffix(%{merged: m, dismissed: d, errors: errors}) do
    parts = []
    parts = if m > 0, do: ["merged #{m} pair(s)" | parts], else: parts
    parts = if d > 0, do: ["dismissed #{d} pair(s)" | parts], else: parts

    parts =
      case errors do
        [] -> parts
        _ -> ["skipped #{length(errors)} (skill not found in target library)" | parts]
      end

    " Dedup: " <> Enum.join(Enum.reverse(parts), ", ") <> "."
  end

  defp dedup_suffix(_), do: ""

  # ── import_library_from_upload ─────────────────────────────────────────

  tool :import_library_from_upload,
       "Import an uploaded structured file (.xlsx/.csv) as a new skill library. " <>
         "Pass upload_id; library_name and column mapping default to the observation's detected hints. " <>
         "v1 supports single-library files only — multi-sheet files where each sheet is a role return an error " <>
         "UNLESS you supply both `sheet` and `library_name`, which imports ONLY that sheet under that library name." do
    param(:upload_id, :string,
      doc: "Upload handle id from list_uploads / observe_upload (e.g. upl_a1b2c3d4)"
    )

    param(:library_name, :string,
      doc: "If omitted, uses the detected library-name column or the filename without extension."
    )

    param(:sheet, :string,
      doc:
        "Excel sheet name to import. If omitted, the first sheet is used. Required (with library_name) for roles-per-sheet files."
    )

    run(fn args, ctx ->
      scope = Scope.from_context(ctx)

      input = %{
        upload_id: args[:upload_id],
        library_name: args[:library_name],
        sheet: args[:sheet]
      }

      case ImportFromUpload.run(input, scope) do
        {:ok, %{libraries: libs, warnings: _warnings}} ->
          text = build_multi_library_text(libs)

          effects =
            [%Rho.Effect.OpenWorkspace{key: :data_table}] ++
              Enum.map(libs, fn lib ->
                %Rho.Effect.Table{
                  table_name: lib.table_name,
                  schema_key: :skill_library,
                  mode_label: "Skill Library — #{lib.library_name}",
                  metadata:
                    library_metadata(lib.library_name, lib.table_name, :import_upload,
                      imported?: true,
                      source_upload_id: args[:upload_id],
                      source_label: args[:sheet] || args[:upload_id]
                    ),
                  rows: [],
                  skip_write?: true
                }
              end)

          %Rho.ToolResponse{text: text, effects: effects}

        {:error, {:partial_import, done, {failed_lib, reason}}} ->
          {:error,
           "Imported #{length(done)} libraries, then failed on '#{failed_lib}': #{inspect(reason)}. Already-imported libraries: #{Enum.map_join(done, ", ", & &1.library_name)}."}

        {:error, {:roles_per_sheet_unsupported_v1, sheets}} ->
          {:error,
           "This file has #{length(sheets)} sheets that look like roles (#{Enum.join(sheets, ", ")}). " <>
             "v1 imports one library per file. Either flatten the sheets into one with a `Skill Library Name` column, " <>
             "or upload each sheet as its own library."}

        {:error, {:library_exists, name}} ->
          {:error, "A library named '#{name}' already exists. Pick a different library_name."}

        {:error, {:ambiguous_shape, _}} ->
          {:error,
           "I can't tell whether this is a single library or multiple. Please specify library_name and re-import."}

        {:error, reason} ->
          {:error, "Import failed: #{inspect(reason)}"}
      end
    end)
  end

  defp build_multi_library_text([single]) do
    "Imported '#{single.library_name}' — #{single.skills_imported} skills, table '#{single.table_name}'."
  end

  defp build_multi_library_text([_, _ | _] = libs) do
    total = Enum.reduce(libs, 0, fn l, acc -> acc + l.skills_imported end)

    per_lib =
      Enum.map_join(libs, ", ", fn l ->
        "#{l.library_name} (#{l.skills_imported} skills)"
      end)

    "Imported #{length(libs)} libraries with #{total} skills total: #{per_lib}."
  end

  # ── extract_role_from_jd ───────────────────────────────────────────────

  tool :extract_role_from_jd,
       "Extract skills from a job description into a skill library and role_profile table. Pass either upload_id or text." do
    param(:upload_id, :string, doc: "Upload handle id, e.g. upl_abc")
    param(:text, :string, doc: "Raw JD text. Mutually exclusive with upload_id.")
    param(:role_name, :string, doc: "Override detected role title.")
    param(:library_name, :string, doc: "Override library name. Defaults to role_name.")

    run(fn args, ctx ->
      scope = Scope.from_context(ctx)

      input = %{
        upload_id: args[:upload_id],
        text: args[:text],
        role_name: args[:role_name],
        library_name: args[:library_name]
      }

      case ExtractFromJD.run(input, scope) do
        {:ok, result} ->
          text = build_jd_extraction_text(result)

          %Rho.ToolResponse{
            text: text,
            effects: [
              %Rho.Effect.OpenWorkspace{key: :data_table},
              %Rho.Effect.Table{
                table_name: result.library_table,
                schema_key: :skill_library,
                mode_label: "Skill Library — #{result.library_name}",
                metadata:
                  library_metadata(result.library_name, result.library_table, :jd_extraction,
                    role_name: result.role_name,
                    source_upload_id: args[:upload_id],
                    source_label: args[:upload_id] || "Pasted job description",
                    linked_role_table: result.role_table
                  ),
                rows: [],
                skip_write?: true
              },
              %Rho.Effect.Table{
                table_name: result.role_table,
                schema_key: :role_profile,
                mode_label: "Role Profile — #{result.role_name}",
                metadata:
                  role_profile_metadata(result.role_name, result.role_table, :jd_extraction,
                    library_name: result.library_name,
                    source_upload_id: args[:upload_id],
                    source_label: args[:upload_id] || "Pasted job description",
                    linked_library_table: result.library_table
                  ),
                rows: [],
                skip_write?: true
              }
            ]
          }

        {:error, :missing_input} ->
          {:error, "Pass either upload_id or text."}

        {:error, :too_many_inputs} ->
          {:error, "Pass either upload_id or text, not both."}

        {:error, {:upload_not_found, upload_id}} ->
          {:error, "Upload '#{upload_id}' was not found."}

        {:error, {:missing_llm_api_key, client, env_var}} ->
          {:error, "#{client} JD extraction requires #{env_var} to be set."}

        {:error, {:unsupported_upload_kind, filename, mime}} ->
          {:error,
           "Unsupported JD upload '#{filename}' (#{mime}). Use a PDF or paste the job description text."}

        {:error, {:library_exists, name}} ->
          {:error, "A library named '#{name}' already exists. Pick a different library_name."}

        {:error, {:role_profile_exists, name}} ->
          {:error, "A role profile named '#{name}' already exists. Pick a different role_name."}

        {:error, :no_skills} ->
          {:error, "No supported skills were extracted from the job description."}

        {:error, reason} ->
          {:error, "extract_role_from_jd failed: #{inspect(reason)}"}
      end
    end)
  end

  defp build_jd_extraction_text(result) do
    "Extracted #{result.skill_count} skill(s) from \"#{result.role_name}\". " <>
      "Created library table \"#{result.library_table}\" and role profile table \"#{result.role_table}\". " <>
      "Required: #{result.required_count}. Nice-to-have: #{result.nice_to_have_count}. " <>
      "Dropped unverified: #{result.dropped_unverified}."
  end

  # ── seed_framework_from_roles ─────────────────────────────────────────

  tool :seed_framework_from_roles,
       "Create a new skill library by unioning the skills from one or more existing role profiles. " <>
         "Use after `analyze_role(action: \"find_similar\")` to combine ESCO occupations (or any saved roles) " <>
         "into a fresh framework. Two ways to specify roles: (a) pass UUIDs in role_profile_ids_json, or " <>
         "(b) set from_selected_candidates: \"true\" to read the user's checked rows from the " <>
         "`role_candidates` table (the typical chat path — agent calls find_similar to populate the picker, " <>
         "user checks rows in the UI, then this tool reads the picks). The new library is created as a " <>
         "draft with skills deduplicated by exact skill ID; the tool surfaces the actual skills that " <>
         "appeared in multiple picked roles. No semantic dedup runs — call `dedup_library(library_id: ...)` " <>
         "explicitly if you want a review tab. Call `save_framework` afterwards to persist further edits." do
    param(:name, :string, required: true, doc: "Name for the new framework")

    param(:role_profile_ids_json, :string,
      doc:
        "Optional JSON array of role profile UUIDs to union, e.g. [\"<uuid-A>\", \"<uuid-B>\"]. " <>
          "Required unless from_selected_candidates is true."
    )

    param(:from_selected_candidates, :string,
      doc:
        "Set to \"true\" to read role_ids from the user's selection in the `role_candidates` table " <>
          "(populated by `analyze_role(find_similar)`). When true, role_profile_ids_json is ignored."
    )

    param(:description, :string, doc: "Optional description for the new library")

    run(fn args, ctx ->
      scope = Scope.from_context(ctx)

      case resolve_seed_role_ids(args, scope) do
        {:ok, ids} ->
          input = %{
            intake: %{
              name: args[:name],
              description: args[:description] || ""
            },
            template_role_ids: ids
          }

          case PickTemplate.run(input, scope) do
            {:ok, %{library_id: library_id, table_name: tbl, row_count: n}} ->
              # Persist the seeded skills to the DB so a follow-up
              # `dedup_library(library_id)` (if the user calls it) has rows
              # to detect against. The library is a draft; further edits
              # in the workspace flow through `save_framework` as usual.
              _ =
                RhoFrameworks.Workbench.save_framework(scope, library_id,
                  table: tbl,
                  archive_research: false
                )

              # The picker has served its purpose. Drop the role_candidates
              # tab so the workspace doesn't show a stale picker. No-op when
              # the table doesn't exist (explicit-IDs path).
              _ = RhoFrameworks.Workbench.drop_role_candidates(scope)

              total_role_skills =
                Roles.count_role_skills_for_profiles(scope.organization_id, ids)

              duplicates =
                Roles.list_cross_role_duplicates(scope.organization_id, ids)

              build_seed_response(
                args[:name],
                tbl,
                n,
                ids,
                total_role_skills,
                duplicates
              )

            {:error, :no_template_selected} ->
              {:error, "role_profile_ids_json must include at least one UUID."}

            {:error, :missing_framework_name} ->
              {:error, "name is required."}

            {:error, reason} ->
              {:error, "seed_framework_from_roles failed: #{inspect(reason)}"}
          end

        {:error, msg} ->
          {:error, msg}
      end
    end)
  end

  defp parse_role_ids(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, ids} when is_list(ids) and ids != [] ->
        if Enum.all?(ids, &(is_binary(&1) and &1 != "")) do
          {:ok, ids}
        else
          {:error, "role_profile_ids_json entries must all be non-empty UUID strings."}
        end

      {:ok, []} ->
        {:error, "role_profile_ids_json must be a non-empty JSON array."}

      {:ok, _} ->
        {:error, "role_profile_ids_json must be a JSON array, not a scalar or object."}

      {:error, _} ->
        {:error, "role_profile_ids_json is not valid JSON."}
    end
  end

  defp parse_role_ids(_), do: {:error, "role_profile_ids_json is required."}

  # Resolve role_ids from either the explicit JSON or the user's selection
  # in the role_candidates table. Selection wins when from_selected_candidates
  # is "true" — the chat-side path users are walked through.
  defp resolve_seed_role_ids(args, scope) do
    if truthy?(args[:from_selected_candidates]) do
      case RhoFrameworks.Workbench.read_selected_candidate_role_ids(scope) do
        [] ->
          {:error,
           "from_selected_candidates: true was passed, but no rows are checked in the " <>
             "role_candidates table. Ask the user to check the rows they want, then retry — " <>
             "or pass role_profile_ids_json explicitly."}

        ids ->
          {:ok, ids}
      end
    else
      parse_role_ids(args[:role_profile_ids_json])
    end
  end

  defp truthy?(v) when v in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  @max_dedup_lines 25

  defp build_seed_response(name, library_table, unique_count, role_ids, total, duplicates) do
    role_count = length(role_ids)

    base =
      "Created framework '#{name}' (table '#{library_table}') with #{unique_count} unique skill(s) from #{role_count} role(s)."

    dedup_section =
      cond do
        duplicates != [] ->
          render_dedup_section(duplicates)

        total > 0 ->
          "All #{total} skill reference(s) across the picked roles are distinct — no overlap to collapse. " <>
            "If you suspect semantically-similar skills, call `dedup_library(library_id: ...)`."

        true ->
          ""
      end

    text =
      case dedup_section do
        "" -> base
        section -> base <> "\n\n" <> section
      end

    library_effect = %Rho.Effect.Table{
      table_name: library_table,
      schema_key: :skill_library,
      mode_label: "Skill Library — #{name}",
      metadata:
        library_metadata(name, library_table, :seed_from_roles,
          generated?: true,
          source_role_profile_ids: role_ids,
          source_label: "Built from #{role_count} selected role(s)"
        ),
      rows: [],
      skip_write?: true
    }

    %Rho.ToolResponse{
      text: text,
      effects: [%Rho.Effect.OpenWorkspace{key: :data_table}, library_effect]
    }
  end

  # Render the list of skills that appeared in multiple picked roles.
  # Truncates long lists at @max_dedup_lines with a count suffix.
  defp render_dedup_section(duplicates) do
    count = length(duplicates)

    {head, tail_count} =
      if count > @max_dedup_lines do
        {Enum.take(duplicates, @max_dedup_lines), count - @max_dedup_lines}
      else
        {duplicates, 0}
      end

    lines = Enum.map(head, &render_dedup_line/1)

    body = Enum.join(lines, "\n")

    suffix =
      if tail_count > 0,
        do: "\n…and #{tail_count} more.",
        else: ""

    header =
      "#{count} skill(s) appeared in multiple picked roles and were collapsed at union time:"

    footer =
      "If you suspect semantically-similar skills also need review, call " <>
        "`dedup_library(library_id: ...)` to open a review tab."

    "#{header}\n#{body}#{suffix}\n\n#{footer}"
  end

  defp render_dedup_line(%{skill_name: name, role_names: roles}) do
    role_text =
      roles
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.sort()
      |> Enum.join(", ")

    "- \"#{name}\" — in #{role_text}"
  end

  defp library_metadata(name, table_name, workflow, opts) do
    %{
      workflow: workflow,
      artifact_kind: :skill_library,
      title: "#{name} Skill Framework",
      library_name: name,
      output_table: table_name,
      persisted?: Keyword.get(opts, :persisted?, false),
      published?: Keyword.get(opts, :published?, false),
      dirty?: Keyword.get(opts, :dirty?, true)
    }
    |> maybe_put(:source_label, Keyword.get(opts, :source_label))
    |> maybe_put(:source_upload_id, Keyword.get(opts, :source_upload_id))
    |> maybe_put(:source_role_profile_ids, Keyword.get(opts, :source_role_profile_ids))
    |> maybe_put(:role_name, Keyword.get(opts, :role_name))
    |> maybe_put(:linked_role_table, Keyword.get(opts, :linked_role_table))
    |> maybe_put(:generated?, Keyword.get(opts, :generated?))
    |> maybe_put(:imported?, Keyword.get(opts, :imported?))
  end

  defp role_profile_metadata(name, table_name, workflow, opts) do
    %{
      workflow: workflow,
      artifact_kind: :role_profile,
      title: "#{name} Role Requirements",
      role_name: name,
      output_table: table_name,
      dirty?: Keyword.get(opts, :dirty?, true)
    }
    |> maybe_put(:library_name, Keyword.get(opts, :library_name))
    |> maybe_put(:linked_library_table, Keyword.get(opts, :linked_library_table))
    |> maybe_put(:source_label, Keyword.get(opts, :source_label))
    |> maybe_put(:source_upload_id, Keyword.get(opts, :source_upload_id))
  end

  # ── clarify ────────────────────────────────────────────────────────────

  tool :clarify,
       "Ask the user a clarifying question when the request is genuinely ambiguous. " <>
         "Use only when no reasonable assumption resolves the ambiguity — otherwise call " <>
         "the use-case tool directly. Calling clarify ends your turn." do
    param(:question, :string, required: true, doc: "The question to ask the user.")

    run(fn args, ctx ->
      question = args[:question] || ""
      session_id = ctx.session_id
      agent_id = ctx.agent_id

      if is_binary(session_id) and question != "" do
        Events.broadcast(
          session_id,
          Events.event(:step_chat_clarify, session_id, agent_id, %{
            question: question,
            agent_id: agent_id
          })
        )
      end

      {:final, question}
    end)
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_matches(matches) do
    lines =
      Enum.map(matches, fn r ->
        name = Rho.MapAccess.get(r, :name)
        id = Rho.MapAccess.get(r, :id)
        family = Rho.MapAccess.get(r, :role_family) || "?"
        count = Rho.MapAccess.get(r, :skill_count) || 0
        "- #{name} (#{id}) — #{family}, #{count} skills"
      end)

    "Found #{length(matches)} similar role(s). Pass the UUID in parens to manage_role(action: \"view\", role_profile_id: ...) to read each role's skills.\n" <>
      Enum.join(lines, "\n")
  end
end
