defmodule Rho.Mounts.Spreadsheet do
  @moduledoc """
  Mount that provides tools for reading and editing a LiveView-managed spreadsheet.

  Write operations (add_rows, replace_all, update_cells, delete_rows) stream
  progressively via the signal bus — the same pattern as LiveRender's `present_ui`.
  Read operations (get_table, get_table_summary) use direct pid messaging for
  synchronous request-response.
  """

  @behaviour Rho.Mount

  alias Rho.Comms

  @registry :rho_spreadsheet_registry
  @stream_batch_size 5

  @doc "Register a LiveView pid for a session. Called by SpreadsheetLive on connect."
  def register(session_id, pid) do
    ensure_table()
    :ets.insert(@registry, {session_id, pid})
  end

  @doc "Unregister a LiveView pid for a session."
  def unregister(session_id) do
    ensure_table()
    :ets.delete(@registry, session_id)
  end

  defp ensure_table do
    if :ets.whereis(@registry) == :undefined do
      :ets.new(@registry, [:named_table, :public, :set, read_concurrency: true])
    end
  rescue
    ArgumentError -> :ok
  end

  @impl Rho.Mount
  def tools(_mount_opts, %{session_id: session_id} = context) do
    [
      get_table_tool(session_id),
      get_table_summary_tool(session_id),
      get_uploaded_file_tool(session_id),
      update_cells_tool(context),
      add_rows_tool(context),
      add_proficiency_levels_tool(session_id, context),
      generate_proficiency_levels_tool(session_id, context),
      delete_rows_tool(context),
      delete_by_filter_tool(session_id, context),
      merge_roles_tool(session_id, context),
      replace_all_tool(context),
      import_from_file_tool(context),
      list_frameworks_tool(context),
      search_framework_roles_tool(context),
      load_framework_tool(session_id, context),
      load_framework_roles_tool(session_id, context),
      save_framework_tool(session_id, context),
      get_company_overview_tool(context),
      get_company_view_tool(context),
      switch_view_tool(context)
    ]
  end

  def tools(_mount_opts, _context), do: []

  @impl Rho.Mount
  def prompt_sections(_mount_opts, _context) do
    [
      """
      # Spreadsheet Editor Context

      You have a spreadsheet with columns:
      id, role, category, cluster, skill_name, skill_description, level, level_name, level_description.

      The "role" field identifies which job role this skill belongs to.
      - Set role when generating/importing skills for a specific role
      - Leave empty for company-wide skills not tied to a role

      Each row represents one proficiency level for one skill. A skill with 5 proficiency levels
      has 5 rows (sharing the same category, cluster, skill_name, skill_description).

      ## Tool Reference
      - `get_table_summary`: Check current state before any changes
      - `get_table`: Read rows, optionally filtered by field/value
      - `add_rows`: Add new rows (pass rows_json — do NOT include "id")
      - `update_cells`: Edit specific cells by row ID
      - `delete_rows`: Remove rows by ID array
      - `replace_all`: Replace the entire table

      ## Row Format
      When adding skeleton rows (Phase 2), use level=0 and level_description="⏳ Pending...":
      {"role": "Data Analyst", "category": "...", "cluster": "...", "skill_name": "...", "skill_description": "...", "level": 0, "level_name": "", "level_description": "⏳ Pending..."}

      When adding proficiency level rows (Phase 3), use level=1-5 with full descriptions.
      """
    ]
  end

  # --- Tool definitions ---

  defp get_table_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "get_table",
          description:
            "Get the current spreadsheet data. Optionally filter by a field name and value. Returns JSON array of rows.",
          parameter_schema: [
            filter_field: [
              type: :string,
              required: false,
              doc: "Field name to filter by, e.g. \"category\""
            ],
            filter_value: [
              type: :string,
              required: false,
              doc: "Value to match, e.g. \"Leadership\""
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        with_pid(session_id, fn pid ->
          filter =
            case {args["filter_field"], args["filter_value"]} do
              {f, v} when is_binary(f) and is_binary(v) -> %{f => v}
              _ -> nil
            end

          ref = make_ref()
          send(pid, {:spreadsheet_get_table, {self(), ref}, filter})

          receive do
            {^ref, {:ok, rows}} -> {:ok, Jason.encode!(rows)}
          after
            5_000 -> {:error, "Spreadsheet did not respond in time"}
          end
        end)
      end
    }
  end

  defp get_table_summary_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "get_table_summary",
          description:
            "Get a summary of the spreadsheet: row count, categories, clusters, and skill counts. Use this before get_table to understand the data without loading all rows.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args ->
        with_pid(session_id, fn pid ->
          ref = make_ref()
          send(pid, {:spreadsheet_get_table, {self(), ref}, nil})

          receive do
            {^ref, {:ok, rows}} -> {:ok, Jason.encode!(build_summary(rows))}
          after
            5_000 -> {:error, "Spreadsheet did not respond in time"}
          end
        end)
      end
    }
  end

  defp get_uploaded_file_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "get_uploaded_file",
          description:
            "Read parsed content of an uploaded file. For large files (>200 rows), " <>
              "returns first 200 rows by default — use offset/limit to paginate.",
          parameter_schema: [
            filename: [
              type: :string,
              required: true,
              doc: "Filename as shown in the upload summary"
            ],
            sheet: [
              type: :string,
              required: false,
              doc: "Sheet name for multi-sheet Excel. Defaults to first sheet."
            ],
            offset: [
              type: :integer,
              required: false,
              doc: "Start row (0-based). Default: 0"
            ],
            limit: [
              type: :integer,
              required: false,
              doc: "Max rows to return. Default: 200"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        with_pid(session_id, fn pid ->
          ref = make_ref()
          send(pid, {:get_uploaded_file, {self(), ref}, args})

          receive do
            {^ref, {:ok, data}} -> {:ok, Jason.encode!(data)}
            {^ref, {:error, reason}} -> {:error, reason}
          after
            5_000 -> {:error, "Spreadsheet did not respond in time"}
          end
        end)
      end
    }
  end

  defp update_cells_tool(context) do
    session_id = context[:session_id]
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "update_cells",
          description:
            "Update specific cells in existing rows. Pass a JSON string of changes array: [{\"id\": 1, \"field\": \"skill_name\", \"value\": \"New Name\"}, ...]",
          parameter_schema: [
            changes_json: [
              type: :string,
              required: true,
              doc:
                "JSON string of changes array: [{\"id\": 1, \"field\": \"skill_name\", \"value\": \"New Name\"}]"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        changes_raw = args["changes_json"] || args[:changes_json] || "[]"

        changes =
          case Jason.decode(changes_raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        publish_spreadsheet_event(session_id, agent_id, :update_cells, %{changes: changes})
        {:ok, "Updated #{length(changes)} cell(s)"}
      end
    }
  end

  defp add_rows_tool(context) do
    session_id = context[:session_id]
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "add_rows",
          description:
            "Add new rows to the spreadsheet. Pass a JSON string of row objects. Do NOT include 'id' — it is assigned automatically. Fields: category, cluster, skill_name, skill_description, level (integer), level_name, level_description.",
          parameter_schema: [
            rows_json: [
              type: :string,
              required: true,
              doc:
                "JSON string of row array, e.g. [{\"category\":\"Leadership\",\"cluster\":\"Strategy\",\"skill_name\":\"Vision\",\"skill_description\":\"...\",\"level\":1,\"level_name\":\"Foundational\",\"level_description\":\"...\"}]"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        rows_raw = args["rows_json"] || args[:rows_json] || "[]"

        rows =
          case Jason.decode(rows_raw) do
            {:ok, list} when is_list(list) -> Enum.map(list, &normalize_row/1)
            _ -> []
          end

        if rows == [] do
          {:error, "No valid rows to add. Ensure rows_json is a valid JSON array."}
        else
          stream_rows_progressive(rows, :add, session_id, agent_id)
          {:ok, "Added #{length(rows)} row(s)"}
        end
      end
    }
  end

  defp add_proficiency_levels_tool(session_id, context) do
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "add_proficiency_levels",
          description:
            "Add proficiency levels for skills. Each entry needs skill_name, category, cluster, skill_description, and a levels array. More token-efficient than add_rows when generating proficiency levels.",
          parameter_schema: [
            levels_json: [
              type: :string,
              required: true,
              doc:
                ~s(JSON string: [{"skill_name":"SQL","category":"Data","cluster":"Wrangling","skill_description":"...","levels":[{"level":1,"level_name":"Novice","level_description":"..."},...]},...]  )
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        raw = args["levels_json"] || args[:levels_json] || "[]"

        skills =
          case Jason.decode(raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        if skills == [] do
          {:error, "No valid data. Ensure levels_json is a valid JSON array."}
        else
          rows =
            Enum.flat_map(skills, fn skill_entry ->
              skill_name = skill_entry["skill_name"] || ""
              role = skill_entry["role"] || ""
              category = skill_entry["category"] || ""
              cluster = skill_entry["cluster"] || ""
              skill_desc = skill_entry["skill_description"] || ""
              levels = skill_entry["levels"] || []

              Enum.map(levels, fn lvl ->
                %{
                  role: role,
                  category: category,
                  cluster: cluster,
                  skill_name: skill_name,
                  skill_description: skill_desc,
                  level: lvl["level"] || 1,
                  level_name: lvl["level_name"] || "",
                  level_description: lvl["level_description"] || ""
                }
              end)
            end)

          if rows == [] do
            {:error, "No levels to add."}
          else
            stream_rows_progressive(rows, :add, session_id, agent_id)
            {:ok, "Added #{length(rows)} proficiency level(s) for #{length(skills)} skill(s)"}
          end
        end
      end
    }
  end

  defp generate_proficiency_levels_tool(session_id, context) do
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "generate_proficiency_levels",
          description:
            "Generate Dreyfus-model proficiency levels (5 levels) for a list of skills using AI. " <>
              "Pass skill metadata — the tool handles LLM generation in parallel and streams results into the spreadsheet. " <>
              "Use this instead of writing proficiency levels yourself.",
          parameter_schema: [
            skills_json: [
              type: :string,
              required: true,
              doc:
                ~s(JSON array of skills: [{"skill_name":"SQL","category":"Data","cluster":"Wrangling","skill_description":"...","role":"Data Analyst"},...]  )
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        raw = args["skills_json"] || args[:skills_json] || "[]"

        skills =
          case Jason.decode(raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        if skills == [] do
          {:error, "No valid skills. Ensure skills_json is a valid JSON array."}
        else
          generate_levels_parallel(skills, session_id, agent_id, context)
        end
      end
    }
  end

  defp generate_levels_parallel(skills, session_id, agent_id, context) do
    require Logger
    prompt = proficiency_system_prompt()
    model = resolve_proficiency_model(context)

    batches = Enum.chunk_every(skills, 6)

    results =
      batches
      |> Task.async_stream(
        fn batch ->
          call_proficiency_llm(batch, model, prompt, session_id, agent_id)
        end,
        max_concurrency: 4,
        timeout: 90_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce({0, 0, []}, fn
        {:ok, {:ok, count}}, {total, batches_done, errors} ->
          {total + count, batches_done + 1, errors}

        {:ok, {:error, reason}}, {total, batches_done, errors} ->
          {total, batches_done + 1, [reason | errors]}

        {:exit, _reason}, {total, batches_done, errors} ->
          {total, batches_done + 1, ["batch timed out" | errors]}
      end)

    {total_levels, _batches_done, errors} = results

    case {total_levels, errors} do
      {0, errs} ->
        {:error, "Failed to generate levels: #{Enum.join(errs, "; ")}"}

      {n, []} ->
        {:ok, "Generated #{n} proficiency level(s) for #{length(skills)} skill(s)"}

      {n, errs} ->
        {:ok,
         "Generated #{n} proficiency level(s) for #{length(skills)} skill(s). " <>
           "#{length(errs)} batch(es) failed: #{Enum.join(errs, "; ")}"}
    end
  end

  defp call_proficiency_llm(skills_batch, model, system_prompt, session_id, agent_id) do
    require Logger

    user_content =
      "Generate 5 Dreyfus proficiency levels for each skill below. " <>
        "Return ONLY a JSON array.\n\n" <>
        Jason.encode!(skills_batch)

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_content}
    ]

    case ReqLLM.generate_text(model, messages, []) do
      {:ok, response} ->
        text = extract_proficiency_text(response)

        case parse_levels_json(text) do
          {:ok, skill_levels} ->
            rows = levels_to_rows(skill_levels, skills_batch)
            stream_rows_progressive(rows, :add, session_id, agent_id)
            {:ok, length(rows)}

          {:error, reason} ->
            Logger.warning("[spreadsheet] proficiency JSON parse failed: #{reason}")
            {:error, "JSON parse failed: #{reason}"}
        end

      {:error, reason} ->
        Logger.warning("[spreadsheet] proficiency LLM call failed: #{inspect(reason)}")
        {:error, "LLM call failed: #{inspect(reason)}"}
    end
  end

  defp extract_proficiency_text(%ReqLLM.Response{message: %{content: content}})
       when is_binary(content),
       do: content

  defp extract_proficiency_text(%ReqLLM.Response{message: %{content: parts}})
       when is_list(parts) do
    # gpt-oss-120b returns ContentParts list (text + thinking).
    # Extract the :text part.
    Enum.find_value(parts, "", fn
      %{type: :text, text: text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp extract_proficiency_text(%{choices: [%{message: %{content: content}} | _]}), do: content

  defp extract_proficiency_text(%{"choices" => [%{"message" => %{"content" => content}} | _]}),
    do: content

  defp extract_proficiency_text(other), do: inspect(other)

  defp parse_levels_json(text) do
    cleaned =
      text
      |> String.replace(~r/```json\s*/, "")
      |> String.replace(~r/```\s*/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _} -> {:error, "expected JSON array"}
      {:error, err} -> {:error, inspect(err)}
    end
  end

  defp levels_to_rows(skill_levels, skills_batch) do
    meta_lookup = Map.new(skills_batch, fn s -> {s["skill_name"], s} end)

    Enum.flat_map(skill_levels, fn skill_entry ->
      skill_name = skill_entry["skill_name"] || ""
      meta = Map.get(meta_lookup, skill_name, %{})
      role = meta["role"] || skill_entry["role"] || ""
      category = meta["category"] || skill_entry["category"] || ""
      cluster = meta["cluster"] || skill_entry["cluster"] || ""
      skill_desc = meta["skill_description"] || skill_entry["skill_description"] || ""
      levels = skill_entry["levels"] || []

      Enum.map(levels, fn lvl ->
        %{
          role: role,
          category: category,
          cluster: cluster,
          skill_name: skill_name,
          skill_description: skill_desc,
          level: lvl["level"] || 1,
          level_name: lvl["level_name"] || "",
          level_description: lvl["level_description"] || ""
        }
      end)
    end)
  end

  defp resolve_proficiency_model(context) do
    agent_name = context[:agent_name] || :spreadsheet
    config = Rho.Config.agent(agent_name)
    config[:proficiency_model] || config[:model] || "openrouter:openai/gpt-oss-120b"
  end

  defp proficiency_system_prompt do
    """
    You generate Dreyfus-model proficiency levels for competency framework skills.

    ## Proficiency Level Model (Dreyfus-based)

    Level 1 — Novice (Foundational):
      Follows established procedures. Needs supervision for non-routine situations.
      Verbs: identifies, follows, recognizes, describes, lists

    Level 2 — Advanced Beginner (Developing):
      Applies learned patterns to real situations. Handles routine tasks independently.
      Verbs: applies, demonstrates, executes, implements, operates

    Level 3 — Competent (Proficient):
      Plans deliberately. Organizes work systematically. Takes ownership of outcomes.
      Verbs: analyzes, organizes, prioritizes, troubleshoots, coordinates

    Level 4 — Advanced (Senior):
      Exercises judgment in ambiguous situations. Mentors others. Optimizes processes.
      Verbs: evaluates, mentors, optimizes, integrates, influences

    Level 5 — Expert (Master):
      Innovates and shapes the field. Operates intuitively. Recognized authority.
      Verbs: architects, transforms, pioneers, establishes, strategizes

    ## Quality Rules
    - Each description MUST be observable: what would you literally SEE this person doing?
    - Format: [action verb] + [core activity] + [context or business outcome]
    - GOOD: "Designs distributed architectures that maintain sub-100ms p99 latency under 10x traffic spikes"
    - BAD: "Is good at system design"
    - Each level assumes mastery of all prior levels — don't repeat lower-level behaviors
    - Levels must be mutually exclusive — if two levels sound interchangeable, rewrite
    - 1-2 sentences per level_description, max

    ## Output Format
    Return ONLY a JSON array. Each entry has skill_name and levels:
    [{"skill_name":"SQL","levels":[{"level":1,"level_name":"Novice","level_description":"..."},...]},...]

    Include ALL skills provided. No markdown, no explanation — just the JSON array.
    """
  end

  defp delete_rows_tool(context) do
    session_id = context[:session_id]
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "delete_rows",
          description: "Delete rows by their IDs.",
          parameter_schema: [
            ids_json: [
              type: :string,
              required: true,
              doc: "JSON string of integer ID array, e.g. [1, 2, 3]"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        ids_raw = args["ids_json"] || args[:ids_json] || "[]"

        ids =
          case Jason.decode(ids_raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        publish_spreadsheet_event(session_id, agent_id, :delete_rows, %{ids: ids})
        {:ok, "Deleted #{length(ids)} row(s)"}
      end
    }
  end

  defp delete_by_filter_tool(session_id, context) do
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "delete_by_filter",
          description:
            "Delete all rows matching a field value. Use instead of get_table + delete_rows " <>
              "when you need to remove rows by category, skill_name, role, or cluster.",
          parameter_schema: [
            field: [
              type: :string,
              required: true,
              doc: "Column name: 'category', 'skill_name', 'role', 'cluster', etc."
            ],
            value: [
              type: :string,
              required: true,
              doc: "Value to match, e.g. 'Power Skills'"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        field = args["field"] || ""
        value = args["value"] || ""

        if field == "" or value == "" do
          {:error, "field and value are required"}
        else
          with_pid(session_id, fn pid ->
            ref = make_ref()
            filter = %{field => value}
            send(pid, {:spreadsheet_get_table, {self(), ref}, filter})

            receive do
              {^ref, {:ok, rows}} ->
                ids = Enum.map(rows, & &1[:id])

                if ids == [] do
                  {:ok, "No rows found where #{field} = '#{value}'"}
                else
                  skill_count = rows |> Enum.map(& &1[:skill_name]) |> Enum.uniq() |> length()
                  publish_spreadsheet_event(session_id, agent_id, :delete_rows, %{ids: ids})

                  {:ok,
                   "Deleted #{length(ids)} row(s) where #{field} = '#{value}' (#{skill_count} skill(s) removed)"}
                end
            after
              5_000 -> {:error, "Spreadsheet did not respond in time"}
            end
          end)
        end
      end
    }
  end

  defp merge_roles_tool(session_id, context) do
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "merge_roles",
          description:
            "Merge two roles into one. Use mode 'plan' first to see the merge plan, " <>
              "then mode 'execute' to apply it. The primary role's skills are kept for " <>
              "shared skills; unique secondary skills are added. All rows renamed to new_role_name.",
          parameter_schema: [
            primary_role: [
              type: :string,
              required: true,
              doc:
                "The role to keep as the base (its proficiency levels are preferred for shared skills)"
            ],
            secondary_role: [
              type: :string,
              required: true,
              doc: "The role to merge in (duplicates removed, unique skills kept)"
            ],
            new_role_name: [
              type: :string,
              required: true,
              doc: "Name for the merged role, e.g. 'Risk Analyst'"
            ],
            mode: [
              type: :string,
              required: true,
              doc: "Either 'plan' (preview changes) or 'execute' (apply changes)"
            ],
            exclude_skills: [
              type: :string,
              required: false,
              doc:
                "JSON array of secondary-only skill names to exclude from merge, e.g. [\"Model Validation\"]"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        primary_role = args["primary_role"] || ""
        secondary_role = args["secondary_role"] || ""
        new_role_name = args["new_role_name"] || ""
        mode = args["mode"] || "plan"

        exclude =
          case Jason.decode(args["exclude_skills"] || "[]") do
            {:ok, list} when is_list(list) -> MapSet.new(list)
            _ -> MapSet.new()
          end

        if primary_role == "" or secondary_role == "" or new_role_name == "" do
          {:error, "primary_role, secondary_role, and new_role_name are all required"}
        else
          case mode do
            "plan" ->
              execute_merge_plan(session_id, primary_role, secondary_role, new_role_name)

            "execute" ->
              execute_merge(
                session_id,
                agent_id,
                primary_role,
                secondary_role,
                new_role_name,
                exclude
              )

            _ ->
              {:error, "mode must be 'plan' or 'execute'"}
          end
        end
      end
    }
  end

  defp execute_merge_plan(session_id, primary_role, secondary_role, new_role_name) do
    with_pid(session_id, fn pid ->
      ref = make_ref()
      send(pid, {:spreadsheet_merge_plan, {self(), ref}, primary_role, secondary_role})

      receive do
        {^ref, {:ok, plan}} ->
          result = %{
            primary_role: primary_role,
            secondary_role: secondary_role,
            new_role_name: new_role_name,
            shared_skills: plan.shared_skills,
            shared_count: plan.shared_count,
            primary_only: plan.primary_only,
            primary_only_count: plan.primary_only_count,
            secondary_only: plan.secondary_only,
            secondary_only_count: plan.secondary_only_count,
            rows_to_delete: plan.rows_to_delete,
            rows_to_keep: plan.rows_after_merge,
            rows_after_merge: plan.rows_after_merge
          }

          {:ok, Jason.encode!(result)}
      after
        5_000 -> {:error, "Spreadsheet did not respond in time"}
      end
    end)
  end

  defp execute_merge(session_id, agent_id, primary_role, secondary_role, new_role_name, exclude) do
    with_pid(session_id, fn pid ->
      ref = make_ref()
      send(pid, {:spreadsheet_merge_plan, {self(), ref}, primary_role, secondary_role})

      receive do
        {^ref, {:ok, plan}} ->
          # Additional IDs to delete: excluded secondary-only skills
          exclude_ids =
            if MapSet.size(exclude) > 0 do
              ref2 = make_ref()
              send(pid, {:spreadsheet_get_table, {self(), ref2}, nil})

              receive do
                {^ref2, {:ok, rows}} ->
                  rows
                  |> Enum.filter(fn row ->
                    row[:role] == secondary_role and MapSet.member?(exclude, row[:skill_name])
                  end)
                  |> Enum.map(& &1[:id])
              after
                5_000 -> []
              end
            else
              []
            end

          all_delete_ids = plan.delete_ids ++ exclude_ids

          # 1. Delete duplicate + excluded rows
          if all_delete_ids != [] do
            publish_spreadsheet_event(session_id, agent_id, :delete_rows, %{ids: all_delete_ids})
          end

          # 2. Rename remaining rows to new_role_name
          rename_ids = plan.rename_ids -- exclude_ids

          if rename_ids != [] do
            changes =
              Enum.map(rename_ids, fn id ->
                %{"id" => id, "field" => "role", "value" => new_role_name}
              end)

            publish_spreadsheet_event(session_id, agent_id, :update_cells, %{changes: changes})
          end

          final_count = length(rename_ids)
          deleted_count = length(all_delete_ids)

          skill_count =
            plan.primary_only_count + plan.shared_count +
              (plan.secondary_only_count - MapSet.size(exclude))

          {:ok,
           Jason.encode!(%{
             deleted_rows: deleted_count,
             renamed_rows: final_count,
             final_skill_count: skill_count,
             final_row_count: final_count,
             new_role_name: new_role_name
           })}
      after
        5_000 -> {:error, "Spreadsheet did not respond in time"}
      end
    end)
  end

  defp replace_all_tool(context) do
    session_id = context[:session_id]
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "replace_all",
          description:
            "Replace the entire spreadsheet with new data. Use for full regeneration. Do NOT include 'id'. Pass a JSON string of row objects.",
          parameter_schema: [
            rows_json: [
              type: :string,
              required: true,
              doc: "JSON string of the complete new dataset array"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        rows_raw = args["rows_json"] || args[:rows_json] || "[]"

        rows =
          case Jason.decode(rows_raw) do
            {:ok, list} when is_list(list) -> Enum.map(list, &normalize_row/1)
            _ -> []
          end

        # Clear table first, then stream rows progressively
        publish_spreadsheet_event(session_id, agent_id, :replace_all, %{})
        stream_rows_progressive(rows, :add, session_id, agent_id)
        {:ok, "Replaced table with #{length(rows)} row(s)"}
      end
    }
  end

  defp list_frameworks_tool(context) do
    %{
      tool:
        ReqLLM.tool(
          name: "list_frameworks",
          description:
            "List available skill frameworks. Returns industry templates visible to all, " <>
              "plus company frameworks for the current company only.",
          parameter_schema: [
            type: [type: :string, required: false, doc: "'industry' or 'company'. Omit for both."]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        company_id = context.opts[:company_id]
        is_admin = context.opts[:is_admin] || false
        type_filter = args["type"]

        frameworks = Rho.SkillStore.list_frameworks_for(company_id, is_admin, type_filter)
        {:ok, Jason.encode!(frameworks)}
      end
    }
  end

  defp search_framework_roles_tool(context) do
    %{
      tool:
        ReqLLM.tool(
          name: "search_framework_roles",
          description:
            "Get a directory of all roles in a framework with skill counts and sample skill names. " <>
              "Use this to browse large industry frameworks before loading — lets you pick specific " <>
              "roles instead of loading everything.",
          parameter_schema: [
            framework_id: [
              type: :integer,
              required: true,
              doc: "Framework ID from list_frameworks"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        framework_id = args["framework_id"]
        company_id = context.opts[:company_id]
        is_admin = context.opts[:is_admin] || false

        case Rho.SkillStore.get_framework(framework_id) do
          nil ->
            {:error, "Framework not found"}

          framework ->
            if can_access?(framework, company_id, is_admin) do
              directory = Rho.SkillStore.get_framework_role_directory(framework_id)
              {:ok, Jason.encode!(%{framework: framework.name, roles: directory})}
            else
              {:error, "Access denied"}
            end
        end
      end
    }
  end

  defp load_framework_tool(session_id, context) do
    %{
      tool:
        ReqLLM.tool(
          name: "load_framework",
          description:
            "Load a framework from the database into the spreadsheet. " <>
              "By default replaces current content. Set append=true to add rows " <>
              "to existing spreadsheet (for loading multiple roles together).",
          parameter_schema: [
            framework_id: [
              type: :integer,
              required: true,
              doc: "Framework ID from list_frameworks"
            ],
            append: [
              type: :boolean,
              required: false,
              doc:
                "If true, append rows to existing spreadsheet instead of replacing. Default: false."
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        framework_id = args["framework_id"]
        append = args["append"] in [true, "true"]
        company_id = context.opts[:company_id]
        is_admin = context.opts[:is_admin] || false

        case Rho.SkillStore.get_framework(framework_id) do
          nil ->
            {:error, "Framework not found"}

          framework ->
            if can_access?(framework, company_id, is_admin) do
              rows = Rho.SkillStore.get_framework_rows(framework_id)

              with_pid(session_id, fn pid ->
                send(pid, {:load_framework_rows, rows, framework, append: append})

                {:ok,
                 "Loaded '#{framework.name}' — #{length(rows)} rows#{if append, do: " (appended)", else: ""}"}
              end)
            else
              {:error, "Access denied"}
            end
        end
      end
    }
  end

  defp load_framework_roles_tool(session_id, context) do
    %{
      tool:
        ReqLLM.tool(
          name: "load_framework_roles",
          description:
            "Load specific roles from a framework into the spreadsheet. Use after " <>
              "search_framework_roles — pass exact role names from the search results. " <>
              "By default replaces current content. Set append=true to add to existing rows.",
          parameter_schema: [
            framework_id: [
              type: :integer,
              required: true,
              doc: "Framework ID from list_frameworks"
            ],
            roles_json: [
              type: :string,
              required: true,
              doc: ~s(JSON array of role names, e.g. ["Risk Analyst", "Credit Risk Manager"])
            ],
            append: [
              type: :boolean,
              required: false,
              doc:
                "If true, append rows to existing spreadsheet instead of replacing. Default: false."
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        framework_id = args["framework_id"]
        append = args["append"] in [true, "true"]
        company_id = context.opts[:company_id]
        is_admin = context.opts[:is_admin] || false

        roles =
          case Jason.decode(args["roles_json"] || "[]") do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        if roles == [] do
          {:error, "No roles specified. Pass roles_json as a JSON array of role name strings."}
        else
          case Rho.SkillStore.get_framework(framework_id) do
            nil ->
              {:error, "Framework not found"}

            framework ->
              if can_access?(framework, company_id, is_admin) do
                rows = Rho.SkillStore.get_framework_rows_for_roles(framework_id, roles)

                with_pid(session_id, fn pid ->
                  send(pid, {:load_framework_rows, rows, framework, append: append})

                  {:ok,
                   "Loaded #{length(roles)} role(s) from '#{framework.name}' — #{length(rows)} rows#{if append, do: " (appended)", else: ""}"}
                end)
              else
                {:error, "Access denied"}
              end
          end
        end
      end
    }
  end

  defp save_framework_tool(session_id, context) do
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "save_framework",
          description:
            "Save the current spreadsheet to the database. Uses two-phase flow: " <>
              "call with mode 'plan' first to get a save plan, then 'execute' to apply. " <>
              "For industry templates (admin only), use type 'industry' to bypass versioning.",
          parameter_schema: [
            mode: [
              type: :string,
              required: true,
              doc: "'plan' (preview save plan) or 'execute' (apply save)"
            ],
            type: [
              type: :string,
              required: false,
              doc: "'company' (default, versioned) or 'industry' (admin only, no versioning)"
            ],
            year: [
              type: :integer,
              required: false,
              doc: "Framework year (required for company type plan mode)"
            ],
            decisions: [
              type: :string,
              required: false,
              doc:
                ~s(JSON array for execute mode: [{"role_name":"Data Scientist","action":"create"},{"role_name":"Risk Analyst","action":"update","existing_id":92}])
            ],
            description: [
              type: :string,
              required: false,
              doc: "Optional note for this version"
            ],
            name: [
              type: :string,
              required: false,
              doc: "Framework name (only for industry type)"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        type = args["type"] || "company"
        company_id = context.opts[:company_id]
        is_admin = context.opts[:is_admin] || false

        cond do
          type == "industry" ->
            if is_admin do
              save_industry_template(session_id, args, company_id)
            else
              {:error, "Only admin can save industry templates"}
            end

          company_id == nil or company_id == "" ->
            {:error, "Company context required. Open the editor with ?company=your_company_id"}

          true ->
            mode = args["mode"] || "plan"
            year = args["year"]

            case mode do
              "plan" ->
                if year == nil do
                  {:error, "year is required for plan mode"}
                else
                  execute_save_plan(session_id, year, company_id)
                end

              "execute" ->
                decisions_raw = args["decisions"]

                if decisions_raw == nil do
                  {:error, "decisions is required for execute mode. Call with mode 'plan' first."}
                else
                  decisions =
                    case Jason.decode(decisions_raw) do
                      {:ok, list} when is_list(list) -> list
                      _ -> []
                    end

                  if decisions == [] do
                    {:error, "No valid decisions. Pass a JSON array."}
                  else
                    execute_save(
                      session_id,
                      agent_id,
                      year || DateTime.utc_now().year,
                      company_id,
                      decisions,
                      args["description"] || ""
                    )
                  end
                end

              _ ->
                {:error, "mode must be 'plan' or 'execute'"}
            end
        end
      end
    }
  end

  defp save_industry_template(session_id, args, _company_id) do
    name = args["name"]

    if name == nil or name == "" do
      {:error, "name is required for industry templates"}
    else
      with_pid(session_id, fn pid ->
        ref = make_ref()
        send(pid, {:get_all_rows, {self(), ref}})

        receive do
          {^ref, {:ok, rows}} ->
            case Rho.SkillStore.save_framework(%{
                   id: args["framework_id"],
                   name: name,
                   type: "industry",
                   company_id: nil,
                   source: "spreadsheet_editor",
                   rows: rows
                 }) do
              {:ok, framework} ->
                {:ok,
                 "Saved industry template '#{name}' (id: #{framework.id}) — #{length(rows)} rows"}

              {:error, reason} ->
                {:error, "Save failed: #{inspect(reason)}"}
            end
        after
          5_000 -> {:error, "Spreadsheet did not respond in time"}
        end
      end)
    end
  end

  defp execute_save_plan(session_id, year, company_id) do
    with_pid(session_id, fn pid ->
      ref = make_ref()
      send(pid, {:spreadsheet_save_plan, {self(), ref}, year, company_id})

      receive do
        {^ref, {:ok, plan}} ->
          {:ok, Jason.encode!(plan)}
      after
        5_000 -> {:error, "Spreadsheet did not respond in time"}
      end
    end)
  end

  defp execute_save(session_id, _agent_id, year, company_id, decisions, description) do
    with_pid(session_id, fn pid ->
      ref = make_ref()
      send(pid, {:get_all_rows, {self(), ref}})

      receive do
        {^ref, {:ok, rows}} ->
          rows_by_role = Enum.group_by(rows, fn row -> row[:role] || "" end)

          results =
            Enum.map(decisions, fn decision ->
              role_name = decision["role_name"]

              action =
                case decision["action"] do
                  "create" -> :create
                  "update" -> :update
                  _ -> :create
                end

              existing_id = decision["existing_id"]
              role_rows = Map.get(rows_by_role, role_name, [])

              if role_rows == [] do
                {:error, "No rows found for role '#{role_name}'"}
              else
                Rho.SkillStore.save_role_framework(%{
                  company_id: company_id,
                  role_name: role_name,
                  year: year,
                  action: action,
                  existing_id: existing_id,
                  description: description,
                  source: "spreadsheet_editor",
                  rows: role_rows
                })
              end
            end)

          successes = Enum.filter(results, &match?({:ok, _}, &1))
          failures = Enum.filter(results, &match?({:error, _}, &1))

          summary =
            successes
            |> Enum.map(fn {:ok, fw} ->
              "#{fw.role_name} #{fw.year} v#{fw.version} (#{fw.row_count} rows)"
            end)
            |> Enum.join(", ")

          case {successes, failures} do
            {[], fails} ->
              {:error, "All saves failed: #{inspect(fails)}"}

            {_, []} ->
              {:ok, "Saved #{length(successes)} role(s): #{summary}"}

            {_, fails} ->
              {:ok,
               "Saved #{length(successes)} role(s): #{summary}. " <>
                 "#{length(fails)} failed: #{inspect(fails)}"}
          end
      after
        5_000 -> {:error, "Spreadsheet did not respond in time"}
      end
    end)
  end

  defp get_company_overview_tool(context) do
    %{
      tool:
        ReqLLM.tool(
          name: "get_company_overview",
          description:
            "Get an overview of the company's skill frameworks — roles, default versions, " <>
              "version history, and available industry templates. Use on first message or " <>
              "when user asks 'what do we have'.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args ->
        company_id = context.opts[:company_id]
        is_admin = context.opts[:is_admin] || false

        if company_id == nil or company_id == "" do
          {:ok,
           Jason.encode!(%{
             company: nil,
             roles: [],
             industry_templates:
               Rho.SkillStore.list_frameworks_for(nil, false, "industry")
               |> Enum.map(&Map.take(&1, [:id, :name, :skill_count, :row_count]))
           })}
        else
          roles_summary = Rho.SkillStore.get_company_roles_summary(company_id)

          industry_templates =
            Rho.SkillStore.list_frameworks_for(company_id, is_admin, "industry")
            |> Enum.map(&Map.take(&1, [:id, :name, :skill_count, :row_count]))

          {:ok,
           Jason.encode!(%{
             company: company_id,
             roles: roles_summary,
             industry_templates: industry_templates
           })}
        end
      end
    }
  end

  defp get_company_view_tool(context) do
    %{
      tool:
        ReqLLM.tool(
          name: "get_company_view",
          description:
            "Get a computed cross-role summary of the company's skill framework. " <>
              "Shows total roles, total unique skills, shared skills across all roles, " <>
              "and per-role breakdowns. Uses default versions only.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args ->
        company_id = context.opts[:company_id]

        if is_nil(company_id) or company_id == "" do
          {:error, "No company specified. Open with ?company=your_company to use this tool."}
        else
          view = Rho.SkillStore.get_company_view(company_id)
          {:ok, Jason.encode!(view, pretty: true)}
        end
      end
    }
  end

  defp switch_view_tool(context) do
    session_id = context[:session_id]

    %{
      tool:
        ReqLLM.tool(
          name: "switch_view",
          description:
            "Switch the spreadsheet view mode. Use 'role' to group by role, 'category' to group by skill category.",
          parameter_schema: [
            mode: [type: :string, required: true, doc: "'role' or 'category'"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        mode = args["mode"]

        with_pid(session_id, fn pid ->
          send(pid, {:switch_view, mode})
          {:ok, "Switched to #{mode} view"}
        end)
      end
    }
  end

  defp import_from_file_tool(context) do
    session_id = context[:session_id]

    %{
      tool:
        ReqLLM.tool(
          name: "import_from_file",
          description:
            "Import rows from a JSON file on disk directly into the spreadsheet. " <>
              "The file must contain a JSON array of row objects. " <>
              "Use this after extracting data with a Python script — the LLM never needs to see the row data.",
          parameter_schema: [
            path: [
              type: :string,
              required: true,
              doc: "Absolute path to a JSON file containing an array of row objects"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        file_path = args["path"]

        with {:ok, content} <- File.read(file_path),
             {:ok, data} <- Jason.decode(content) do
          rows =
            case data do
              list when is_list(list) -> Enum.map(list, &normalize_row/1)
              _ -> []
            end

          if rows == [] do
            {:error, "No valid rows in file. Expected a JSON array of row objects."}
          else
            # Bulk load — send all rows in one event (no progressive streaming)
            # to avoid 400+ small DOM updates that crash the browser
            with_pid(session_id, fn pid ->
              send(pid, {:bulk_import_rows, rows})
              {:ok, "Imported #{length(rows)} row(s) from #{file_path}"}
            end)
          end
        else
          {:error, :enoent} -> {:error, "File not found: #{file_path}"}
          {:error, reason} -> {:error, "Failed to read file: #{inspect(reason)}"}
        end
      end
    }
  end

  defp can_access?(_framework, _company_id, true = _is_admin), do: true
  defp can_access?(%{type: "industry"}, _company_id, _is_admin), do: true

  defp can_access?(framework, company_id, _is_admin) do
    Map.get(framework, :company_id) == company_id
  end

  # --- Signal bus publishing (progressive streaming) ---

  defp stream_rows_progressive(rows, op, session_id, agent_id) do
    batches = Enum.chunk_every(rows, @stream_batch_size)

    batches
    |> Enum.with_index()
    |> Enum.each(fn {batch, idx} ->
      if idx > 0, do: Process.sleep(30)

      publish_spreadsheet_event(session_id, agent_id, :rows_delta, %{
        rows: batch,
        op: op
      })
    end)
  end

  defp publish_spreadsheet_event(session_id, agent_id, event_type, payload) do
    topic = "rho.session.#{session_id}.events.spreadsheet_#{event_type}"
    source = "/session/#{session_id}/agent/#{agent_id}"

    Comms.publish(
      topic,
      Map.merge(payload, %{session_id: session_id, agent_id: agent_id}),
      source: source
    )
  end

  # --- Helpers ---

  defp with_pid(session_id, fun) do
    ensure_table()

    case :ets.lookup(@registry, session_id) do
      [{_, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: fun.(pid), else: {:error, "Spreadsheet not connected"}

      _ ->
        {:error, "Spreadsheet not connected"}
    end
  end

  defp normalize_row(row) when is_map(row) do
    %{
      role: row["role"] || row[:role] || "",
      category: row["category"] || row[:category] || "",
      cluster: row["cluster"] || row[:cluster] || "",
      skill_name: row["skill_name"] || row[:skill_name] || "",
      skill_description: row["skill_description"] || row[:skill_description] || "",
      level: row["level"] || row[:level] || 1,
      level_name: row["level_name"] || row[:level_name] || "",
      level_description: row["level_description"] || row[:level_description] || ""
    }
  end

  defp build_summary(rows) do
    roles =
      rows
      |> Enum.map(fn r -> r[:role] || Map.get(r, :role) end)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    categories =
      rows
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {cat, cat_rows} ->
        clusters =
          cat_rows
          |> Enum.group_by(& &1.cluster)
          |> Enum.map(fn {cluster, cluster_rows} ->
            skills = cluster_rows |> Enum.map(& &1.skill_name) |> Enum.uniq()
            %{cluster: cluster, skill_count: length(skills), skills: skills}
          end)

        %{category: cat, cluster_count: length(clusters), clusters: clusters}
      end)

    %{
      total_rows: length(rows),
      total_categories: length(categories),
      total_skills: rows |> Enum.map(& &1.skill_name) |> Enum.uniq() |> length(),
      total_roles: length(roles),
      roles: roles,
      categories: categories
    }
  end
end
