defmodule RhoFrameworks.SkeletonGenerator do
  @moduledoc """
  LLM-backed skill skeleton generation via AgentJobs.

  Spawns an async agent job using the `:spreadsheet` agent config (Structured
  turn strategy) so the LLM output streams to the UI via Comms events.
  The worker calls `create_library` then `save_skeletons` to persist
  results into a DataTable.
  """

  alias RhoFrameworks.AgentJobs
  alias RhoFrameworks.MapAccess
  alias RhoFrameworks.Scope

  @doc """
  Spawn an agent job to generate skill skeletons for a new framework.

  Accepts enriched params from the wizard flow:
  - `name`, `description` (required)
  - `skill_count` — target number of skills (default 12)
  - `domain` — domain context (e.g. "Software Engineering")
  - `target_roles` — comma-separated target roles
  - `similar_role_skills` — seed skills from similar existing roles

  Returns `{:ok, %{agent_id: String.t()}}` immediately. The worker runs
  asynchronously; listen for `rho.task.completed` + data_table events.
  """
  @spec generate(map(), Scope.t()) :: {:ok, %{agent_id: String.t()}} | {:error, term()}
  def generate(params, %Scope{} = scope) do
    name = params[:name] || ""
    description = params[:description] || ""

    config = Rho.Config.agent_config(:spreadsheet)
    tools = resolve_tools(scope)
    skill_count = skill_count_range(params)
    task_prompt = build_task_prompt(name, description, skill_count, params)

    {:ok, agent_id} =
      AgentJobs.start(
        task: task_prompt,
        parent_agent_id: scope.session_id,
        tools: tools,
        model: config.model,
        system_prompt: config.system_prompt,
        max_steps: config[:max_steps] || 10,
        turn_strategy: Map.get(config, :turn_strategy),
        provider: config[:provider],
        agent_name: :spreadsheet,
        session_id: scope.session_id,
        organization_id: scope.organization_id
      )

    publish_started(scope, agent_id)

    {:ok, %{agent_id: agent_id}}
  end

  defp skill_count_range(params) do
    count = to_int(params[:skill_count], 12)
    # Allow ±4 around the target for LLM flexibility
    lo = max(count - 4, 5)
    hi = count + 4
    "#{lo}-#{hi}"
  end

  defp to_int(v, _default) when is_integer(v), do: v

  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_int(_, default), do: default

  defp build_task_prompt(name, description, skill_range, params) do
    context_block = format_context_block(params)

    """
    Create a skill framework called "#{name}".

    Description: #{description}
    #{context_block}
    IMPORTANT: You must call tools ONE AT A TIME in this exact order:

    Step 1: Call create_library with name="#{name}" and description="#{description}". Wait for the result.
    Step 2: Call save_skeletons with library_name="#{name}" and a skills_json JSON array of #{skill_range} skills. Each skill needs: category, cluster, skill_name, skill_description. Wait for the result.
    Step 3: Call finish.

    Do NOT call multiple tools in one turn. Call one tool, wait for the result, then proceed.
    """
  end

  defp format_context_block(params) do
    lines =
      [
        format_param(params, :domain, "Domain: "),
        format_param(params, :target_roles, "Target roles: "),
        format_param(params, :similar_role_skills, "Seed context from similar roles:\n")
      ]
      |> Enum.reject(&is_nil/1)

    if lines == [], do: "", else: "\n" <> Enum.join(lines, "\n") <> "\n"
  end

  defp format_param(params, key, prefix) do
    value = params[key] || params[Atom.to_string(key)]
    if is_binary(value) and value != "", do: prefix <> value
  end

  @doc """
  Returns tool_defs available to the skeleton generator worker.
  """
  def resolve_tools(%Scope{} = _scope) do
    # Build a minimal context for tool resolution — tools don't depend on context fields
    ctx = %Rho.Context{agent_name: :spreadsheet}
    library_tools = RhoFrameworks.Tools.LibraryTools.__tools__(ctx)

    # Only include manage_library (for create action)
    manage_tool = Enum.find(library_tools, fn t -> t.tool.name == "manage_library" end)

    [manage_tool, save_skeletons_tool(), Rho.Stdlib.Tools.Finish.tool_def()]
    |> Enum.reject(&is_nil/1)
  end

  defp save_skeletons_tool do
    %{
      tool:
        ReqLLM.tool(
          name: "save_skeletons",
          description:
            "Save skill skeletons to the library table. Call AFTER create_library. " <>
              "Provide skills_json as a JSON array of {category, cluster, skill_name, skill_description} objects.",
          parameter_schema: [
            {:skills_json, [type: :string, required: true, doc: "JSON array of skill objects"]},
            {:library_name,
             [type: :string, required: true, doc: "Library name from create_library"]}
          ],
          callback: fn _ -> :ok end
        ),
      execute: &execute_save_skeletons/2
    }
  end

  defp execute_save_skeletons(args, ctx) do
    raw = MapAccess.get(args, :skills_json, [])
    skills = if is_binary(raw), do: elem(Jason.decode(raw), 1), else: raw
    library_name = MapAccess.get(args, :library_name, nil)

    if is_nil(library_name) or library_name == "" do
      {:error, "library_name is required. Pass the exact name used in create_library."}
    else
      save_skills_to_table(library_name, skills, ctx)
    end
  end

  defp save_skills_to_table(library_name, skills, ctx) do
    alias RhoFrameworks.Library.{Editor, Skeletons}

    table_name = Editor.table_name(library_name)
    rows = Skeletons.to_rows(skills)
    scope = Scope.from_context(ctx)

    case Editor.append_rows(%{table_name: table_name, rows: rows}, scope) do
      {:ok, %{count: count}} ->
        {:ok, "Saved #{count} skill skeleton(s) to table '#{table_name}'."}

      {:error, :empty_list} ->
        {:error, "No valid data. Ensure skills_json is a non-empty JSON array."}

      {:error, {:json_decode, _}} ->
        {:error, "Invalid JSON. Ensure skills_json is a valid JSON array."}

      {:error, {:missing_required_keys, _keys, _count}} ->
        {:error, "Each skill needs at least category and skill_name."}

      {:error, {:not_running, _}} ->
        {:error, "Table not found. You must call create_library first before save_skeletons."}

      {:error, reason} ->
        {:error, "Failed: #{inspect(reason)}"}
    end
  end

  defp publish_started(%Scope{session_id: nil}, _agent_id), do: :ok

  defp publish_started(%Scope{} = scope, agent_id) do
    data = %{
      session_id: scope.session_id,
      agent_id: scope.session_id,
      worker_agent_id: agent_id,
      role: :skeleton_generator,
      task: "Generating skill framework"
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
