defmodule RhoFrameworks.UseCases.GenerateSkillsForTaxonomy do
  @moduledoc """
  Generate library skill rows underneath an approved taxonomy draft.

  Reads `taxonomy:<name>` by default, renders it into the LLM prompt, and
  writes valid skills into `library:<name>` using the existing Workbench API.
  """

  @behaviour RhoFrameworks.UseCase

  require Logger

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.LLM.GenerateSkillsForTaxonomy, as: LLM
  alias RhoFrameworks.Scope
  alias RhoFrameworks.Taxonomy
  alias RhoFrameworks.Workbench

  @impl true
  def describe do
    %{
      id: :generate_skills_for_taxonomy,
      label: "Generate skills for taxonomy",
      cost_hint: :cheap,
      doc:
        "Generates skill rows under the approved taxonomy and writes them into the library table."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    name = Rho.MapAccess.get(input, :name) || ""
    description = Rho.MapAccess.get(input, :description) || ""

    cond do
      blank?(name) -> {:error, :missing_name}
      blank?(description) -> {:error, :missing_description}
      true -> do_run(name, description, input, scope)
    end
  end

  defp do_run(name, description, input, %Scope{session_id: session_id} = scope)
       when is_binary(session_id) do
    preferences = Taxonomy.parse_preferences(input)

    taxonomy_table_name =
      Rho.MapAccess.get(input, :taxonomy_table_name) || Taxonomy.table_name(name)

    table_name = Rho.MapAccess.get(input, :table_name) || Taxonomy.library_table_name(name)
    agent_id = Rho.MapAccess.get(input, :agent_id)

    with :ok <- ensure_session_tables(session_id, table_name),
         {:ok, taxonomy_rows} <- load_taxonomy_rows(session_id, taxonomy_table_name, preferences),
         seam_input <- build_seam_input(name, description, input, preferences, taxonomy_rows),
         {:ok, persisted_state, returned, rejected} <-
           run_seam(scope, table_name, agent_id, taxonomy_rows, seam_input) do
      {:ok,
       %{
         returned: returned,
         added: persisted_state.added,
         rejected: rejected,
         rejected_count: length(rejected),
         table_name: table_name,
         taxonomy_table_name: taxonomy_table_name,
         library_name: name
       }}
    end
  end

  defp do_run(_name, _description, _input, _scope), do: {:error, :missing_session_id}

  defp ensure_session_tables(session_id, table_name) do
    with {:ok, _pid} <- DataTable.ensure_started(session_id),
         :ok <- DataTable.ensure_table(session_id, table_name, DataTableSchemas.library_schema()) do
      :ok
    else
      {:error, reason} -> {:error, {:ensure_table_failed, reason}}
    end
  end

  defp load_taxonomy_rows(session_id, table_name, preferences) do
    case DataTable.get_rows(session_id, table: table_name) do
      rows when is_list(rows) ->
        case Taxonomy.normalize_rows(rows, preferences) do
          [] -> {:error, :empty_taxonomy}
          normalized -> {:ok, normalized}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_seam(scope, table_name, agent_id, taxonomy_rows, seam_input) do
    allowed = Taxonomy.allowed_pairs(taxonomy_rows)

    on_partial = fn
      :skill, %{} = skill -> handle_skill(scope, agent_id, table_name, skill, allowed)
      _, _ -> :ok
    end

    case generate_fn().(seam_input, on_partial) do
      {:ok, %{} = result} ->
        skills = extract_skills(result)

        rejected =
          skills
          |> Enum.reject(&Taxonomy.allowed_skill?(&1, allowed))
          |> Enum.map(&skill_identity/1)

        skills
        |> Enum.filter(&Taxonomy.allowed_skill?(&1, allowed))
        |> Enum.each(&handle_skill(scope, agent_id, table_name, &1, allowed))

        state = %{added: read_added_rows(scope.session_id, table_name)}
        {:ok, state, length(skills), rejected}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_generate_skills_result, other}}
    end
  end

  defp handle_skill(scope, agent_id, table_name, skill, allowed) do
    if Taxonomy.allowed_skill?(skill, allowed) do
      case to_row(skill) do
        {:ok, row} ->
          case Workbench.add_skill(scope, row, table: table_name) do
            {:ok, _row} ->
              broadcast_partial(scope, agent_id, "→ skill: #{row.skill_name}")

            {:error, {:duplicate_skill_name, _}} ->
              :ok

            {:error, reason} ->
              Logger.warning(fn ->
                "[GenerateSkillsForTaxonomy] add_skill failed: #{inspect(reason)} " <>
                  "table=#{inspect(table_name)} row=#{inspect(row)}"
              end)
          end

        :skip ->
          :ok
      end
    else
      :ok
    end
  end

  defp to_row(skill) when is_map(skill) do
    name = get(skill, :name)
    cluster = get(skill, :cluster)
    description = get(skill, :description)
    category = get(skill, :category)

    if blank?(name) or blank?(cluster) or blank?(description) or blank?(category) do
      :skip
    else
      {:ok,
       %{
         skill_name: name,
         cluster: cluster,
         category: category,
         skill_description: description
       }}
    end
  end

  defp to_row(_), do: :skip

  defp build_seam_input(name, description, input, preferences, taxonomy_rows) do
    %{
      name: name,
      description: description,
      target_roles: blank_to_dash(Rho.MapAccess.get(input, :target_roles)),
      research: blank_to_dash(Rho.MapAccess.get(input, :research)),
      seeds:
        blank_to_dash(
          Rho.MapAccess.get(input, :seeds) ||
            Rho.MapAccess.get(input, :similar_role_skills)
        ),
      taxonomy: Taxonomy.render_rows(taxonomy_rows),
      existing_skills: blank_to_dash(Rho.MapAccess.get(input, :existing_skills)),
      gaps: blank_to_dash(Rho.MapAccess.get(input, :gaps)),
      skills_per_cluster: to_hint(preferences.skills_per_cluster),
      strict_counts: to_string(preferences.strict_counts)
    }
  end

  defp generate_fn do
    Application.get_env(
      :rho_frameworks,
      :generate_skills_for_taxonomy_fn,
      &__MODULE__.default_generate/2
    )
  end

  @doc "Default seam around `LLM.GenerateSkillsForTaxonomy.stream/2`."
  @spec default_generate(map(), (atom(), map() -> any())) :: {:ok, map()} | {:error, term()}
  def default_generate(input, on_partial) do
    pd_count_key = {__MODULE__, :default_skill_count, make_ref()}
    Process.put(pd_count_key, 0)

    callback = fn partial -> maybe_emit_skills(partial, on_partial, pd_count_key) end

    try do
      case LLM.stream(input, callback) do
        {:ok, %LLM{skills: skills}} ->
          {:ok, %{skills: normalize_skills(skills)}}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Process.delete(pd_count_key)
    end
  end

  defp maybe_emit_skills(partial, on_partial, pd_count_key) do
    skills = extract_skills(partial)
    already = Process.get(pd_count_key, 0)

    newly =
      skills
      |> Enum.drop(already)
      |> Enum.take_while(&fully_formed_skill?/1)

    Enum.each(newly, fn skill -> on_partial.(:skill, skill) end)
    Process.put(pd_count_key, already + length(newly))
  end

  defp extract_skills(partial) when is_map(partial) do
    case get(partial, :skills) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp extract_skills(_), do: []

  defp fully_formed_skill?(skill) when is_map(skill) do
    not blank?(get(skill, :name)) and
      not blank?(get(skill, :cluster)) and
      not blank?(get(skill, :description)) and
      not blank?(get(skill, :category))
  end

  defp fully_formed_skill?(_), do: false

  defp normalize_skills(skills) when is_list(skills) do
    Enum.map(skills, fn skill ->
      %{
        category: get(skill, :category),
        cluster: get(skill, :cluster),
        name: get(skill, :name),
        description: get(skill, :description),
        cited_findings: get(skill, :cited_findings) || []
      }
    end)
  end

  defp normalize_skills(_), do: []

  defp read_added_rows(session_id, table_name) do
    case DataTable.get_rows(session_id, table: table_name) do
      rows when is_list(rows) ->
        Enum.map(rows, fn row ->
          %{
            name: Rho.MapAccess.get(row, :skill_name),
            category: Rho.MapAccess.get(row, :category),
            cluster: Rho.MapAccess.get(row, :cluster)
          }
        end)

      _ ->
        []
    end
  end

  defp skill_identity(skill) do
    %{
      name: get(skill, :name),
      category: get(skill, :category),
      cluster: get(skill, :cluster)
    }
  end

  defp broadcast_partial(%Scope{session_id: nil}, _agent_id, _line), do: :ok

  defp broadcast_partial(%Scope{session_id: session_id}, agent_id, line)
       when is_binary(session_id) do
    event_agent_id = agent_id || session_id

    event =
      Rho.Events.event(:structured_partial, session_id, event_agent_id, %{
        text: line <> "\n",
        source: :flow_use_case
      })

    Rho.Events.broadcast(session_id, event)
    Rho.Agent.Worker.touch_activity(agent_id)
  end

  defp blank_to_dash(nil), do: "(none)"
  defp blank_to_dash(""), do: "(none)"
  defp blank_to_dash(s) when is_binary(s), do: s
  defp blank_to_dash(list) when is_list(list), do: Enum.map_join(list, "\n", &inspect/1)
  defp blank_to_dash(_), do: "(none)"

  defp to_hint(nil), do: "(none)"
  defp to_hint(value), do: to_string(value)

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp get(_, _), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
