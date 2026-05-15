defmodule RhoFrameworks.UseCases.GenerateProficiency do
  @moduledoc """
  Fan out per-category proficiency-level generation across the skeleton
  rows already in a framework's library table.

  Phase 7 of `docs/swappable-decision-policy-plan.md`: each fan-out
  worker is a streaming `RhoBaml.Function` call, not an agent loop. One
  Task per category runs under `Rho.TaskSupervisor`, streams
  `RhoFrameworks.LLM.WriteProficiencyLevels`, and pipes each
  fully-formed skill through `RhoFrameworks.Workbench.set_proficiency/4`
  as it arrives.

  ## Events

  Each worker emits two events on the session topic so the existing
  `fan_out_step` UI keeps working unchanged:

    * `:task_requested` at spawn — payload includes `worker_agent_id`,
      `role: :proficiency_writer`, and a human-readable task summary.
    * `:task_completed` at finish — payload includes `worker_agent_id`,
      `status: :ok | :error`, and a result string. Sibling worker
      crashes never propagate; a `:task_completed` with `status: :error`
      is emitted before the Task exits.

  ## Test seam

  The LLM half is overridable via Application env. The seam fn takes
  `(input, on_partial)`; it must invoke `on_partial.(skill)` for each
  fully-formed skill (with `:skill_name` and `:levels`) it decides to
  emit. Persistence (Workbench) stays inside the UseCase:

      Application.put_env(:rho_frameworks, :write_proficiency_levels_fn,
        fn _input, on_partial ->
          on_partial.(%{
            skill_name: "Vim",
            levels: [%{level: 1, level_name: "Novice", level_description: "..."}]
          })
          {:ok, %{skills: [%{...}]}}
        end)

  The default impl wraps `LLM.WriteProficiencyLevels.stream/3` and
  detects newly-completed entries as the BAML structured stream grows.
  """

  @behaviour RhoFrameworks.UseCase

  require Logger

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.LLM.WriteProficiencyLevels, as: LLM
  alias RhoFrameworks.MapAccess
  alias RhoFrameworks.Scope
  alias RhoFrameworks.Workbench

  @default_levels 5

  @impl true
  def describe do
    %{
      id: :generate_proficiency,
      label: "Generate proficiency levels",
      cost_hint: :cheap,
      doc:
        "Per-category fan-out of streaming BAML calls — one Task per category writes " <>
          "Dreyfus-model proficiency levels back into the library table via Workbench."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    table_name = Rho.MapAccess.get(input, :table_name)
    raw_levels = Rho.MapAccess.get(input, :levels)
    parent_agent_id = Rho.MapAccess.get(input, :agent_id)

    cond do
      # Skip silently when no levels were explicitly chosen. This is the
      # contract that lets non-scratch paths in the create flow bypass
      # proficiency generation entirely — they save with empty
      # `proficiency_levels` and the user fills them in later via the
      # edit flow's `:choose_levels` step. Scratch sets levels in
      # `intake_scratch`; edit sets it in `:choose_levels`.
      is_nil(raw_levels) or raw_levels == "" ->
        {:ok, %{skipped: true, reason: :no_levels_chosen}}

      is_nil(table_name) or table_name == "" ->
        {:error, :missing_table_name}

      is_nil(scope.session_id) ->
        {:error, :missing_session_id}

      true ->
        levels = parse_levels(raw_levels)
        start_fanout(table_name, levels, parent_agent_id, scope)
    end
  end

  # Coerce a string/integer level count into an integer, falling back to
  # the default if parsing fails. Mirrors finalize_skeleton's parse_levels
  # so this UseCase is callable with either shape.
  defp parse_levels(n) when is_integer(n), do: n

  defp parse_levels(n) when is_binary(n) do
    case Integer.parse(n) do
      {n, _} -> n
      :error -> @default_levels
    end
  end

  defp parse_levels(_), do: @default_levels

  # ──────────────────────────────────────────────────────────────────────
  # Fan-out
  # ──────────────────────────────────────────────────────────────────────

  defp start_fanout(table_name, levels, parent_agent_id, %Scope{} = scope) do
    case DataTable.get_rows(scope.session_id, table: table_name) do
      {:error, :not_running} ->
        {:error, {:not_running, table_name}}

      [] ->
        {:error, :empty_rows}

      rows when is_list(rows) ->
        # Per-skill scale check: skip rows whose existing proficiency_levels
        # array length already matches the user's chosen scale. Rows with no
        # proficiency get generated; rows at a different scale get
        # regenerated. Implements the "stick with current = additive,
        # change = regenerate" semantic without touching anything else.
        rows_to_generate = Enum.reject(rows, &already_at_scale?(&1, levels))

        if rows_to_generate == [] do
          {:ok, %{skipped: true, reason: :all_skills_already_at_scale}}
        else
          by_category = Enum.group_by(rows_to_generate, &MapAccess.get(&1, :category))

          if map_size(by_category) == 0 do
            {:error, :empty_rows}
          else
            workers =
              Enum.map(by_category, fn {category, cat_skills} ->
                spawn_category_worker(
                  category,
                  cat_skills,
                  levels,
                  table_name,
                  parent_agent_id,
                  scope
                )
              end)

            {:async, %{workers: workers}}
          end
        end
    end
  end

  defp already_at_scale?(row, levels) do
    case MapAccess.get(row, :proficiency_levels) do
      list when is_list(list) -> length(list) == levels
      _ -> false
    end
  end

  defp spawn_category_worker(
         category,
         cat_skills,
         num_levels,
         table_name,
         parent_agent_id,
         %Scope{} = scope
       ) do
    worker_agent_id = Rho.Agent.Primary.new_agent_id(scope.session_id)
    count = length(cat_skills)

    publish_requested(scope, parent_agent_id, worker_agent_id, category, count)

    seam_input = build_seam_input(category, cat_skills, num_levels)
    persist_scope = %{scope | source: scope.source || :flow}

    Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
      run_worker(
        persist_scope,
        parent_agent_id,
        worker_agent_id,
        category,
        table_name,
        seam_input
      )
    end)

    %{agent_id: worker_agent_id, category: category, count: count}
  end

  defp run_worker(scope, parent_agent_id, worker_agent_id, category, table_name, seam_input) do
    on_partial = fn skill ->
      persist_skill(scope, parent_agent_id, table_name, skill)
    end

    try do
      result = write_fn().(seam_input, on_partial)
      summary = summarize_worker_result(category, result)
      publish_completed(scope, parent_agent_id, worker_agent_id, summary.status, summary.result)
    rescue
      e ->
        Logger.warning(fn ->
          "[GenerateProficiency] worker crashed (#{category}): " <>
            Exception.message(e) <>
            "\n" <> Exception.format_stacktrace(__STACKTRACE__)
        end)

        publish_completed(
          scope,
          parent_agent_id,
          worker_agent_id,
          :error,
          "crashed: #{Exception.message(e)}"
        )
    end
  end

  defp summarize_worker_result(category, {:ok, _data}),
    do: %{status: :ok, result: "proficiency: #{category} ok"}

  defp summarize_worker_result(category, {:error, reason}),
    do: %{status: :error, result: "proficiency: #{category} error: #{inspect(reason)}"}

  defp summarize_worker_result(category, _other),
    do: %{status: :error, result: "proficiency: #{category} unexpected"}

  # ──────────────────────────────────────────────────────────────────────
  # Persistence
  # ──────────────────────────────────────────────────────────────────────

  defp persist_skill(%Scope{} = scope, parent_agent_id, table_name, skill) do
    skill_name = MapAccess.get(skill, :skill_name)
    levels = MapAccess.get(skill, :levels) || []

    cond do
      blank?(skill_name) ->
        :ok

      levels == [] ->
        :ok

      true ->
        case Workbench.set_proficiency(scope, skill_name, normalize_levels(levels),
               table: table_name
             ) do
          {:ok, _row} ->
            broadcast_partial(
              scope,
              parent_agent_id,
              "→ levels: #{skill_name} (#{length(levels)} lvls)"
            )

            :ok

          {:error, reason} ->
            Logger.warning(fn ->
              "[GenerateProficiency] set_proficiency failed for #{inspect(skill_name)}: " <>
                inspect(reason)
            end)

            :ok
        end
    end
  end

  defp broadcast_partial(%Scope{session_id: nil}, _agent_id, _line), do: :ok

  defp broadcast_partial(%Scope{session_id: session_id}, agent_id, line)
       when is_binary(session_id) do
    # Attribute the partial to the parent agent (chat agent) so the LV
    # appends the streaming text to that agent's chat thread. Falling
    # back to session_id sends it to a phantom agent that has no UI tab.
    event_agent_id = agent_id || session_id

    event =
      Rho.Events.event(:structured_partial, session_id, event_agent_id, %{
        text: line <> "\n",
        source: :flow_use_case
      })

    Rho.Events.broadcast(session_id, event)
  end

  defp normalize_levels(levels) when is_list(levels) do
    Enum.map(levels, fn lvl ->
      %{
        level: MapAccess.get(lvl, :level, 1),
        level_name: MapAccess.get(lvl, :level_name),
        level_description: MapAccess.get(lvl, :level_description)
      }
    end)
  end

  defp normalize_levels(_), do: []

  # ──────────────────────────────────────────────────────────────────────
  # Seam input
  # ──────────────────────────────────────────────────────────────────────

  defp build_seam_input(category, cat_skills, num_levels) do
    %{
      category: category || "(uncategorised)",
      levels: num_levels,
      skills: format_skills(cat_skills)
    }
  end

  defp format_skills(cat_skills) do
    cat_skills
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {row, idx} ->
      name = MapAccess.get(row, :skill_name)
      cluster = MapAccess.get(row, :cluster) || ""
      desc = MapAccess.get(row, :skill_description) || ""
      "#{idx}. #{name} | Cluster: #{cluster} | #{desc}"
    end)
  end

  # ──────────────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────────────

  defp publish_requested(%Scope{session_id: nil}, _parent, _worker, _category, _count), do: :ok

  defp publish_requested(%Scope{} = scope, parent, worker, category, count) do
    # `agent_id` is the *parent* (chat agent) so the LV appends the
    # delegation card to its chat thread. `worker_agent_id` identifies
    # the spawned writer separately for status updates.
    parent = parent || scope.session_id

    data = %{
      session_id: scope.session_id,
      agent_id: parent,
      worker_agent_id: worker,
      role: :proficiency_writer,
      task: "Proficiency levels: #{category} (#{count} skills)"
    }

    Rho.Events.broadcast(
      scope.session_id,
      Rho.Events.event(:task_requested, scope.session_id, parent, data)
    )
  end

  defp publish_completed(%Scope{session_id: nil}, _parent, _worker, _status, _result), do: :ok

  defp publish_completed(%Scope{} = scope, parent, worker, status, result) do
    parent = parent || scope.session_id

    data = %{
      session_id: scope.session_id,
      agent_id: parent,
      worker_agent_id: worker,
      status: status,
      result: result
    }

    Rho.Events.broadcast(
      scope.session_id,
      Rho.Events.event(:task_completed, scope.session_id, parent, data)
    )
  end

  # ──────────────────────────────────────────────────────────────────────
  # Default seam — wraps LLM.WriteProficiencyLevels.stream/3
  # ──────────────────────────────────────────────────────────────────────

  defp write_fn do
    Application.get_env(
      :rho_frameworks,
      :write_proficiency_levels_fn,
      &__MODULE__.default_write/2
    )
  end

  @doc """
  Default `:write_proficiency_levels_fn` — bridges
  `LLM.WriteProficiencyLevels.stream/3` to the `(input, on_partial)`
  shape. Tracks how many fully-formed skills have already been forwarded
  so each new entry surfaces exactly once as the BAML structured stream
  grows.
  """
  @spec default_write(map(), (map() -> any())) :: {:ok, map()} | {:error, term()}
  def default_write(input, on_partial) do
    pd_key = {__MODULE__, :persisted_count, make_ref()}
    Process.put(pd_key, 0)

    # BAML emits each `skills[]` element atomically thanks to
    # `@@stream.done` on the inner class (see WriteProficiencyLevels
    # schema). Every partial we observe is fully formed, so a simple
    # drop-already-emitted loop is safe — no need to skip the tail.
    callback = fn partial ->
      skills = extract_skills(partial)
      already = Process.get(pd_key, 0)

      newly =
        skills
        |> Enum.drop(already)
        |> Enum.take_while(&fully_formed_skill?/1)

      Enum.each(newly, on_partial)
      Process.put(pd_key, already + length(newly))
    end

    try do
      case LLM.stream(input, callback) do
        {:ok, %LLM{skills: skills}} ->
          {:ok, %{skills: normalize_skill_payload(skills)}}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Process.delete(pd_key)
    end
  end

  defp normalize_skill_payload(skills) when is_list(skills) do
    Enum.map(skills, fn skill ->
      %{
        skill_name: MapAccess.get(skill, :skill_name),
        levels: normalize_levels(MapAccess.get(skill, :levels) || [])
      }
    end)
  end

  defp normalize_skill_payload(_), do: []

  # ──────────────────────────────────────────────────────────────────────
  # Misc helpers
  # ──────────────────────────────────────────────────────────────────────

  defp extract_skills(partial) when is_map(partial) do
    case MapAccess.get(partial, :skills) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp extract_skills(_), do: []

  defp fully_formed_skill?(skill) when is_map(skill) do
    name = MapAccess.get(skill, :skill_name)
    levels = MapAccess.get(skill, :levels)

    not blank?(name) and is_list(levels) and levels != [] and
      Enum.all?(levels, &fully_formed_level?/1)
  end

  defp fully_formed_skill?(_), do: false

  defp fully_formed_level?(level) when is_map(level) do
    is_integer(MapAccess.get(level, :level)) and
      not blank?(MapAccess.get(level, :level_name)) and
      not blank?(MapAccess.get(level, :level_description))
  end

  defp fully_formed_level?(_), do: false

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end