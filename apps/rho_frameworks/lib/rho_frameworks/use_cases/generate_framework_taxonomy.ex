defmodule RhoFrameworks.UseCases.GenerateFrameworkTaxonomy do
  @moduledoc """
  Generate a session-scoped taxonomy draft before skill generation.

  Rows land in `taxonomy:<name>` as one category/cluster row per cluster.
  No library skill rows are created by this use case.
  """

  @behaviour RhoFrameworks.UseCase

  require Logger

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.LLM.GenerateTaxonomy, as: LLM
  alias RhoFrameworks.Scope
  alias RhoFrameworks.Taxonomy
  alias RhoFrameworks.Workbench

  @impl true
  def describe do
    %{
      id: :generate_framework_taxonomy,
      label: "Generate framework taxonomy",
      cost_hint: :cheap,
      doc:
        "Drafts the category/cluster taxonomy first and writes reviewable rows into taxonomy:<name>."
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
    taxonomy_table_name = Taxonomy.table_name(name)
    preferences = Taxonomy.parse_preferences(input)
    agent_id = Rho.MapAccess.get(input, :agent_id)

    with :ok <- ensure_session_tables(session_id, taxonomy_table_name),
         :ok <- set_meta(scope, name, description, Rho.MapAccess.get(input, :target_roles)),
         seam_input <- build_seam_input(name, description, input, preferences),
         {:ok, result} <- run_seam(scope, agent_id, taxonomy_table_name, preferences, seam_input),
         rows <- Taxonomy.rows_from_result(result, preferences),
         {:ok, final_rows} <- DataTable.replace_all(session_id, rows, table: taxonomy_table_name) do
      broadcast_partial(scope, agent_id, "→ taxonomy reconciled: #{length(final_rows)} clusters")

      {:ok,
       %{
         taxonomy_table_name: taxonomy_table_name,
         table_name: taxonomy_table_name,
         library_name: name,
         category_count: count_categories(final_rows),
         cluster_count: length(final_rows),
         preferences: preferences
       }}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_taxonomy_result, other}}
    end
  end

  defp do_run(_name, _description, _input, _scope), do: {:error, :missing_session_id}

  defp ensure_session_tables(session_id, taxonomy_table_name) do
    with {:ok, _pid} <- DataTable.ensure_started(session_id),
         :ok <-
           DataTable.ensure_table(
             session_id,
             taxonomy_table_name,
             DataTableSchemas.taxonomy_schema()
           ),
         :ok <- DataTable.ensure_table(session_id, "meta", DataTableSchemas.meta_schema()) do
      :ok
    else
      {:error, reason} -> {:error, {:ensure_table_failed, reason}}
    end
  end

  defp set_meta(scope, name, description, target_roles) do
    case Workbench.set_meta(scope, %{
           name: name,
           description: description,
           target_roles: target_roles
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:set_meta_failed, reason}}
    end
  end

  defp run_seam(scope, agent_id, taxonomy_table_name, preferences, seam_input) do
    on_partial = fn
      :cluster, %{} = cluster ->
        handle_cluster(scope, agent_id, taxonomy_table_name, preferences, cluster)

      _, _ ->
        :ok
    end

    case generate_fn().(seam_input, on_partial) do
      {:ok, %{} = result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_generate_taxonomy_result, other}}
    end
  end

  defp handle_cluster(scope, agent_id, taxonomy_table_name, preferences, cluster) do
    case Taxonomy.normalize_rows([cluster], preferences) do
      [row] ->
        case DataTable.add_rows(scope.session_id, [row], table: taxonomy_table_name) do
          {:ok, [_]} ->
            broadcast_partial(scope, agent_id, "→ cluster: #{row.category} / #{row.cluster}")

          {:error, {:duplicate_id, _}} ->
            :ok

          {:error, reason} ->
            Logger.warning(fn ->
              "[GenerateFrameworkTaxonomy] add cluster failed: #{inspect(reason)} row=#{inspect(row)}"
            end)
        end

      _ ->
        :ok
    end
  end

  defp build_seam_input(name, description, input, preferences) do
    %{
      name: name,
      description: description,
      domain: blank_to_dash(Rho.MapAccess.get(input, :domain)),
      target_roles: blank_to_dash(Rho.MapAccess.get(input, :target_roles)),
      research: blank_to_dash(Rho.MapAccess.get(input, :research)),
      seeds:
        blank_to_dash(
          Rho.MapAccess.get(input, :seeds) || Rho.MapAccess.get(input, :similar_role_skills)
        ),
      source_evidence: blank_to_dash(Rho.MapAccess.get(input, :source_evidence)),
      taxonomy_size: preferences.taxonomy_size,
      category_count: int_to_string(preferences.category_count),
      clusters_per_category: to_hint(preferences.clusters_per_category),
      skills_per_cluster: to_hint(preferences.skills_per_cluster),
      strict_counts: to_string(preferences.strict_counts),
      specificity: preferences.specificity,
      transferability: preferences.transferability,
      generation_style: preferences.generation_style
    }
  end

  defp generate_fn do
    Application.get_env(:rho_frameworks, :generate_taxonomy_fn, &__MODULE__.default_generate/2)
  end

  @doc "Default seam around `LLM.GenerateTaxonomy.stream/2`."
  @spec default_generate(map(), (atom(), map() -> any())) :: {:ok, map()} | {:error, term()}
  def default_generate(input, on_partial) do
    pd_count_key = {__MODULE__, :emitted_clusters, make_ref()}
    Process.put(pd_count_key, 0)

    callback = fn partial -> maybe_emit_clusters(partial, on_partial, pd_count_key) end

    try do
      case LLM.stream(input, callback) do
        {:ok, %LLM{name: name, description: description, categories: categories}} ->
          {:ok,
           %{name: name, description: description, categories: normalize_categories(categories)}}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Process.delete(pd_count_key)
    end
  end

  defp maybe_emit_clusters(partial, on_partial, pd_count_key) do
    clusters = flatten_clusters(partial)
    already = Process.get(pd_count_key, 0)

    newly =
      clusters
      |> Enum.drop(already)
      |> Enum.take_while(&fully_formed_cluster?/1)

    Enum.each(newly, fn row -> on_partial.(:cluster, row) end)
    Process.put(pd_count_key, already + length(newly))
  end

  defp normalize_categories(categories) when is_list(categories) do
    Enum.map(categories, fn category ->
      %{
        name: get(category, :name),
        description: get(category, :description),
        rationale: get(category, :rationale),
        clusters:
          category
          |> get(:clusters)
          |> List.wrap()
          |> Enum.map(fn cluster ->
            %{
              name: get(cluster, :name),
              description: get(cluster, :description),
              rationale: get(cluster, :rationale),
              target_skill_count: get(cluster, :target_skill_count),
              transferability: get(cluster, :transferability)
            }
          end)
      }
    end)
  end

  defp normalize_categories(_), do: []

  defp flatten_clusters(partial) do
    partial
    |> get(:categories)
    |> List.wrap()
    |> Enum.flat_map(fn category ->
      category
      |> get(:clusters)
      |> List.wrap()
      |> Enum.map(fn cluster ->
        %{
          category: get(category, :name),
          category_description: get(category, :description),
          cluster: get(cluster, :name),
          cluster_description: get(cluster, :description),
          target_skill_count: get(cluster, :target_skill_count),
          transferability: get(cluster, :transferability),
          rationale: get(cluster, :rationale) || get(category, :rationale)
        }
      end)
    end)
  end

  defp fully_formed_cluster?(row) do
    not blank?(get(row, :category)) and
      not blank?(get(row, :cluster)) and
      not blank?(get(row, :cluster_description))
  end

  defp count_categories(rows) do
    rows
    |> Enum.map(&Rho.MapAccess.get(&1, :category))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> length()
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
  defp blank_to_dash(_), do: "(none)"

  defp int_to_string(nil), do: "(none)"
  defp int_to_string(n) when is_integer(n), do: Integer.to_string(n)

  defp to_hint(nil), do: "(none)"
  defp to_hint(value), do: to_string(value)

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp get(_, _), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
