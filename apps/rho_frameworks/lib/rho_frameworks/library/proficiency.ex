defmodule RhoFrameworks.Library.Proficiency do
  @moduledoc """
  LiteWorker fan-out orchestration for proficiency level generation.

  Extracted from the `save_and_generate` tool. Groups skills by category,
  builds per-category prompts, and spawns staggered LiteWorkers.

  All functions take `Runtime.t()` — no `Rho.Context` or agent infra leaks
  into the public API. A minimal `Rho.Context` is constructed internally
  for LiteWorker compatibility.
  """

  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.MapAccess
  alias RhoFrameworks.Runtime

  @stagger_ms 250

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
    # SharedTools.__tools__/1 needs a context-like arg; we pass a minimal
    # struct — the tool definitions themselves don't depend on context fields.
    ctx = %Rho.Context{agent_name: :proficiency_writer}
    shared_tools = RhoFrameworks.Tools.SharedTools.__tools__(ctx)
    shared_tools ++ [Rho.Stdlib.Tools.Finish.tool_def()]
  end

  @doc """
  Spawn staggered LiteWorkers for proficiency generation, one per category.

  Groups `rows` by category, builds prompts, and spawns workers with a
  #{@stagger_ms}ms delay between each to avoid connection pool exhaustion.

  Returns `{:ok, %{workers: [%{agent_id, category, count}]}}`.
  """
  @spec start_fanout(
          %{rows: [map()], levels: pos_integer(), table_name: String.t()},
          Runtime.t()
        ) :: {:ok, %{workers: [map()]}} | {:error, term()}
  def start_fanout(%{rows: rows, levels: num_levels, table_name: table_name}, %Runtime{} = rt) do
    if rows == [] do
      {:error, :empty_rows}
    else
      by_category = Enum.group_by(rows, fn r -> MapAccess.get(r, :category) end)
      role_config = Rho.Config.agent_config(:proficiency_writer)
      tools = resolve_tools()
      parent_id = Runtime.lite_parent_id(rt)
      lite_ctx = build_lite_context(rt)

      workers =
        by_category
        |> Enum.with_index()
        |> Enum.map(fn {{category, cat_skills}, idx} ->
          if idx > 0, do: Process.sleep(@stagger_ms)

          # Build prompt from the original parsed skills (string-keyed maps)
          # or from DataTable rows (atom-keyed). build_prompt handles both via || fallback.
          task_prompt =
            build_prompt(%{
              category: category,
              skills: cat_skills,
              levels: num_levels,
              table_name: table_name
            })

          {:ok, agent_id} =
            Rho.Agent.LiteWorker.start(
              task: task_prompt,
              parent_agent_id: parent_id,
              tools: tools,
              role: :proficiency_writer,
              max_steps: Map.get(role_config, :max_steps, 5),
              context: %{lite_ctx | subagent: true}
            )

          publish_delegation(rt, agent_id, category, length(cat_skills))

          %{agent_id: agent_id, category: category, count: length(cat_skills)}
        end)

      {:ok, %{workers: workers}}
    end
  end

  @doc """
  Read rows from DataTable, then delegate to `start_fanout/2`.
  """
  @spec start_fanout_from_table(
          %{table_name: String.t(), levels: pos_integer()},
          Runtime.t()
        ) :: {:ok, %{workers: [map()]}} | {:error, term()}
  def start_fanout_from_table(%{table_name: table_name, levels: levels}, %Runtime{} = rt) do
    case Editor.read_rows(%{table_name: table_name}, rt) do
      {:ok, rows} ->
        start_fanout(%{rows: rows, levels: levels, table_name: table_name}, rt)

      {:error, _} = err ->
        err
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  # Build a minimal Rho.Context for LiteWorker compatibility.
  # LiteWorker uses session_id for event publishing and agent_name for
  # config lookup.
  defp build_lite_context(%Runtime{} = rt) do
    %Rho.Context{
      agent_name: :proficiency_writer,
      agent_id: rt.execution_id,
      session_id: rt.session_id,
      organization_id: rt.organization_id
    }
  end

  defp publish_delegation(%Runtime{session_id: nil}, _agent_id, _category, _count), do: :ok

  defp publish_delegation(%Runtime{} = rt, agent_id, category, count) do
    Rho.Comms.publish(
      "rho.task.requested",
      %{
        session_id: rt.session_id,
        agent_id: rt.execution_id,
        worker_agent_id: agent_id,
        role: :proficiency_writer,
        task: "Proficiency levels: #{category} (#{count} skills)"
      },
      source: "/session/#{rt.session_id}/agent/#{agent_id}"
    )
  end
end
