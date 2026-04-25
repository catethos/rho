defmodule RhoFrameworks.Library.Proficiency do
  @moduledoc """
  AgentJobs fan-out orchestration for proficiency level generation.

  Groups skills by category, builds per-category prompts, and spawns
  staggered agent jobs. Config is inlined — proficiency writers are
  internal workers, not user-facing agents.

  All functions take `Scope.t()` — no `Rho.Context` or agent infra leaks
  into the public API.
  """

  alias RhoFrameworks.AgentJobs
  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.MapAccess
  alias RhoFrameworks.Scope

  @stagger_ms 250

  # Inlined from .rho.exs — proficiency writers are internal workers
  @model "openrouter:openai/gpt-oss-120b"
  @provider %{order: ["Cerebras", "Groq", "Fireworks"]}
  @turn_strategy Rho.TurnStrategy.TypedStructured
  @max_steps 15
  @system_prompt """
  You generate proficiency levels for competency framework skills.

  ## Input
  You receive: a category name, the number of levels to generate, and a list of skills
  (each with skill_name, cluster, and skill_description).

  IMPORTANT: Generate proficiency levels ONLY for the exact skill_names provided.
  Do NOT add, rename, split, or merge skills. The skills already exist in the data table
  as skeleton rows — your job is to add proficiency levels to them, not create new skills.

  ## Dreyfus proficiency model

  Use this as a baseline — adapt level names and count to match what was requested.
  If asked for fewer than 5 levels, select the most meaningful subset (e.g., for 2 levels:
  Foundational + Advanced; for 3: Foundational + Proficient + Expert).

  Level 1 — Novice: Follows procedures, needs supervision. Verbs: identifies, follows, recognizes
  Level 2 — Advanced Beginner: Applies patterns independently. Verbs: applies, demonstrates, executes
  Level 3 — Competent: Plans deliberately, owns outcomes. Verbs: analyzes, organizes, prioritizes
  Level 4 — Advanced: Exercises judgment, mentors others. Verbs: evaluates, mentors, optimizes
  Level 5 — Expert: Innovates, recognized authority. Verbs: architects, transforms, pioneers

  ## Quality rules
  - Each description MUST be observable: what would you literally SEE this person doing?
  - Format: [action verb] + [core activity] + [context or business outcome]
  - GOOD: "Designs distributed architectures that maintain sub-100ms p99 latency under 10x traffic spikes"
  - BAD: "Is good at system design"
  - Each level assumes mastery of prior levels — don't repeat lower-level behaviors
  - Levels must be mutually exclusive — if two levels sound interchangeable, rewrite
  - 1-2 sentences per level_description, max

  ## Output
  Call `add_proficiency_levels` once with ALL skills in your assigned category.
  Use the EXACT skill_name values from the input — the tool matches by skill_name to
  update existing skeleton rows. Skills with names that don't match will be skipped.

  If the task prompt mentions a table name (e.g. `table: "library:<framework>"`), pass it
  as the `table:` argument. If the tool returns "No matching skeleton skills found", read
  the error message — it lists the session's known tables. Retry once with a table from
  that list whose name starts with `library:`. Do not invent table names.

  Do NOT call delete_rows, add_rows, or any other tool. Only call add_proficiency_levels, then finish.
  """

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Build the proficiency writer prompt for a single category.

  Pure function — no IO.
  """
  @spec build_prompt(%{
          category: String.t(),
          skills: [map()],
          levels: pos_integer(),
          table_name: String.t()
        }) :: String.t()
  def build_prompt(%{
        category: category,
        skills: skills,
        levels: num_levels,
        table_name: table_name
      }) do
    skill_lines =
      skills
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, i} ->
        name = MapAccess.get(s, :skill_name)
        cluster = MapAccess.get(s, :cluster)
        desc = MapAccess.get(s, :skill_description)
        "#{i}. #{name} | Cluster: #{cluster} | #{desc}"
      end)

    """
    Generate #{num_levels}-level Dreyfus-model proficiency levels for the following skills.

    Category: #{category}
    Levels: #{num_levels}

    Skills:
    #{skill_lines}

    Call add_proficiency_levels once with ALL skills above. Use the EXACT skill_name values.
    IMPORTANT: Pass table: "#{table_name}" to add_proficiency_levels.
    """
  end

  @doc """
  Returns tool_defs for proficiency writers (SharedTools + Finish).
  """
  @spec resolve_tools() :: [map()]
  def resolve_tools do
    ctx = %Rho.Context{agent_name: :proficiency_writer}
    shared_tools = RhoFrameworks.Tools.SharedTools.__tools__(ctx)
    shared_tools ++ [Rho.Stdlib.Tools.Finish.tool_def()]
  end

  @doc """
  Spawn staggered agent jobs for proficiency generation, one per category.

  Groups `rows` by category, builds prompts, and spawns workers with a
  #{@stagger_ms}ms delay between each to avoid connection pool exhaustion.

  Returns `{:ok, %{workers: [%{agent_id, category, count}]}}`.
  """
  @spec start_fanout(
          %{rows: [map()], levels: pos_integer(), table_name: String.t()},
          Scope.t()
        ) :: {:ok, %{workers: [map()]}} | {:error, term()}
  def start_fanout(%{rows: rows, levels: num_levels, table_name: table_name}, %Scope{} = scope) do
    if rows == [] do
      {:error, :empty_rows}
    else
      by_category = Enum.group_by(rows, fn r -> MapAccess.get(r, :category) end)
      tools = resolve_tools()

      fanout_opts = %{
        num_levels: num_levels,
        table_name: table_name,
        tools: tools
      }

      workers =
        by_category
        |> Enum.with_index()
        |> Enum.map(fn {{category, cat_skills}, idx} ->
          spawn_category_worker(category, cat_skills, idx, fanout_opts, scope)
        end)

      {:ok, %{workers: workers}}
    end
  end

  @doc """
  Read rows from DataTable, then delegate to `start_fanout/2`.
  """
  @spec start_fanout_from_table(
          %{table_name: String.t(), levels: pos_integer()},
          Scope.t()
        ) :: {:ok, %{workers: [map()]}} | {:error, term()}
  def start_fanout_from_table(%{table_name: table_name, levels: levels}, %Scope{} = scope) do
    case Editor.read_rows(%{table_name: table_name}, scope) do
      {:ok, rows} ->
        start_fanout(%{rows: rows, levels: levels, table_name: table_name}, scope)

      {:error, _} = err ->
        err
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp spawn_category_worker(category, cat_skills, idx, opts, scope) do
    if idx > 0, do: Process.sleep(@stagger_ms)

    task_prompt =
      build_prompt(%{
        category: category,
        skills: cat_skills,
        levels: opts.num_levels,
        table_name: opts.table_name
      })

    {:ok, agent_id} =
      AgentJobs.start(
        task: task_prompt,
        parent_agent_id: scope.session_id,
        tools: opts.tools,
        model: @model,
        system_prompt: @system_prompt,
        max_steps: @max_steps,
        turn_strategy: @turn_strategy,
        provider: @provider,
        agent_name: :proficiency_writer,
        session_id: scope.session_id,
        organization_id: scope.organization_id
      )

    publish_delegation(scope, agent_id, category, length(cat_skills))

    %{agent_id: agent_id, category: category, count: length(cat_skills)}
  end

  defp publish_delegation(%Scope{session_id: nil}, _agent_id, _category, _count), do: :ok

  defp publish_delegation(%Scope{} = scope, agent_id, category, count) do
    data = %{
      session_id: scope.session_id,
      agent_id: scope.session_id,
      worker_agent_id: agent_id,
      role: :proficiency_writer,
      task: "Proficiency levels: #{category} (#{count} skills)"
    }

    Rho.Comms.publish(
      "rho.task.requested",
      data,
      source: "/session/#{scope.session_id}/agent/#{agent_id}"
    )

    maybe_broadcast_event(:task_requested, scope.session_id, agent_id, data)
  end

  defp maybe_broadcast_event(kind, session_id, agent_id, data)
       when is_binary(session_id) do
    case Application.get_env(:rho, :event_broadcaster) do
      nil -> :ok
      mod -> mod.broadcast_event(kind, session_id, agent_id, data)
    end
  end

  defp maybe_broadcast_event(_, _, _, _), do: :ok
end
