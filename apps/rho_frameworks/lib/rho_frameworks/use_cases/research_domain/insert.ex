defmodule RhoFrameworks.UseCases.ResearchDomain.Insert do
  @moduledoc """
  Direct Exa-backed workhorse for the research-domain step.

  This module owns the synchronous path:
  input -> focused Exa searches -> deduped mapped rows -> `research_notes`.
  """

  alias Rho.Stdlib.DataTable
  alias Rho.Stdlib.DataTable.Schema
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.UseCases.ResearchDomain.Mapper

  @table_name "research_notes"
  @default_limit 10
  @per_query_results 5
  @max_concurrency 2
  @task_timeout 20_000

  @spec run(map(), String.t(), atom()) ::
          {:ok,
           %{
             table_name: String.t(),
             inserted: non_neg_integer(),
             seen: non_neg_integer(),
             failed_queries: non_neg_integer()
           }}
          | {:error, term()}
  def run(input, session_id, source)
      when is_map(input) and is_binary(session_id) and is_atom(source) do
    with :ok <- ensure_research_table(session_id),
         {:ok, summary} <- search_and_insert(input, session_id, source) do
      {:ok, Map.put(summary, :table_name, @table_name)}
    end
  end

  def run(_input, _session_id, _source), do: {:error, :missing_session_id}

  def table_name, do: @table_name

  defp ensure_research_table(session_id) do
    schema = DataTableSchemas.research_notes_schema()

    with {:ok, _pid} <- DataTable.ensure_started(session_id),
         :ok <- ensure_or_upgrade_research_table(session_id, schema) do
      :ok
    else
      {:error, reason} -> {:error, {:ensure_table_failed, reason}}
    end
  end

  defp ensure_or_upgrade_research_table(session_id, schema) do
    case DataTable.get_schema(session_id, @table_name) do
      {:ok, existing_schema} ->
        cond do
          schemas_compatible?(existing_schema, schema) -> :ok
          legacy_research_schema?(existing_schema) -> upgrade_research_table(session_id, schema)
          true -> {:error, :schema_mismatch}
        end

      {:error, :not_found} ->
        DataTable.ensure_table(session_id, @table_name, schema)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schemas_compatible?(%Schema{} = existing, %Schema{} = incoming) do
    existing.mode == incoming.mode and
      Schema.column_names(existing) == Schema.column_names(incoming) and
      existing.children_key == incoming.children_key and
      Schema.child_column_names(existing) == Schema.child_column_names(incoming) and
      existing.child_key_fields == incoming.child_key_fields
  end

  defp schemas_compatible?(_, _), do: false

  defp upgrade_research_table(session_id, schema) do
    case DataTable.get_rows(session_id, table: @table_name) do
      rows when is_list(rows) ->
        replace_research_table(session_id, schema, rows)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:upgrade_failed, other}}
    end
  end

  defp replace_research_table(session_id, schema, rows) do
    with :ok <- DataTable.drop_table(session_id, @table_name),
         :ok <- DataTable.ensure_table(session_id, @table_name, schema),
         {:ok, _rows} <-
           DataTable.replace_all(session_id, normalize_legacy_rows(rows), table: @table_name) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:upgrade_failed, other}}
    end
  end

  defp legacy_research_schema?(%Schema{} = schema) do
    schema.mode == :strict and
      Schema.column_names(schema) == [:source, :fact, :tag, :pinned, :_source]
  end

  defp legacy_research_schema?(_), do: false

  defp normalize_legacy_rows(rows) do
    Enum.map(rows, fn row ->
      %{
        source: get(row, :source),
        source_title: nil,
        fact: get(row, :fact),
        published_date: nil,
        relevance: nil,
        tag: get(row, :tag),
        pinned: get(row, :pinned),
        _source: get(row, :_source)
      }
    end)
  end

  defp search_and_insert(input, session_id, source) do
    client = Application.get_env(:rho_frameworks, :exa_client, RhoFrameworks.ExaClient)
    summary_query = summary_query(input)
    queries = queries(input)

    initial = %{
      inserted: 0,
      seen: 0,
      failed_queries: 0,
      errors: [],
      remaining: row_limit(input),
      seen_urls: MapSet.new()
    }

    queries
    |> Task.async_stream(
      fn query ->
        {query,
         client.search(query, num_results: @per_query_results, summary_query: summary_query)}
      end,
      max_concurrency: min(length(queries), @max_concurrency),
      ordered: false,
      timeout: @task_timeout
    )
    |> Enum.reduce_while(initial, fn result, acc ->
      case handle_search_result(result, acc, session_id, source) do
        {:ok, acc} -> {:cont, acc}
        {:error, reason} -> {:halt, Map.put(acc, :fatal_error, reason)}
      end
    end)
    |> finalize_summary(length(queries))
  end

  defp queries(input) do
    name = get(input, :name)
    description = get(input, :description)
    domain = get(input, :domain)
    target_roles = get(input, :target_roles)

    role_skills =
      [name, target_roles, domain, "role skills competency framework"]
      |> compact_join(" ")

    trends =
      [description, target_roles, "required skills trends"]
      |> compact_join(" ")

    standards =
      [domain || name, target_roles, "professional standards competency framework"]
      |> compact_join(" ")

    [role_skills, trends, standards]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> case do
      [] ->
        [
          "skill framework competencies",
          "required skills trends",
          "professional standards competency framework"
        ]

      list ->
        Enum.take(list, 3)
    end
  end

  defp summary_query(input) do
    [
      get(input, :name),
      get(input, :description) || get(input, :domain) || get(input, :target_roles)
    ]
    |> compact_join(" - ")
    |> case do
      "" -> "skill framework competencies"
      query -> query
    end
  end

  defp handle_search_result({:ok, {_query, {:ok, results}}}, acc, session_id, source)
       when is_list(results) do
    {unique_results, seen_urls} = dedupe_by_url(results, acc.seen_urls)

    rows =
      unique_results
      |> map_rows(acc.remaining)

    case insert_rows(session_id, rows, source) do
      {:ok, inserted} ->
        {:ok,
         %{
           acc
           | inserted: acc.inserted + inserted,
             seen: acc.seen + length(results),
             remaining: max(acc.remaining - inserted, 0),
             seen_urls: seen_urls
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_search_result({:ok, {_query, {:error, reason}}}, acc, _session_id, _source) do
    {:ok, note_query_failure(acc, reason)}
  end

  defp handle_search_result({:exit, reason}, acc, _session_id, _source) do
    {:ok, note_query_failure(acc, {:task_exit, reason})}
  end

  defp handle_search_result(_result, acc, _session_id, _source) do
    {:ok, note_query_failure(acc, :unexpected_result)}
  end

  defp note_query_failure(acc, reason) do
    %{
      acc
      | failed_queries: acc.failed_queries + 1,
        errors: [reason | acc.errors]
    }
  end

  defp finalize_summary(%{fatal_error: reason}, _query_count), do: {:error, reason}

  defp finalize_summary(%{inserted: 0, failed_queries: failed, errors: [reason | _]}, query_count)
       when failed == query_count do
    {:error, reason}
  end

  defp finalize_summary(acc, _query_count) do
    summary =
      acc
      |> Map.take([:inserted, :seen, :failed_queries])

    {:ok, summary}
  end

  defp dedupe_by_url(results, seen_urls) do
    {seen, unique} =
      Enum.reduce(results, {seen_urls, []}, fn result, {seen, acc} ->
        url = result |> get(:url) |> normalize_url()

        cond do
          is_nil(url) -> {seen, acc}
          MapSet.member?(seen, url) -> {seen, acc}
          true -> {MapSet.put(seen, url), [result | acc]}
        end
      end)

    {Enum.reverse(unique), seen}
  end

  defp map_rows(results, limit) do
    results
    |> Enum.map(&Mapper.to_row/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(limit)
  end

  defp insert_rows(_session_id, [], _source), do: {:ok, 0}

  defp insert_rows(session_id, rows, source) do
    previous_source = Process.get(:rho_source)
    Process.put(:rho_source, source)

    result =
      case DataTable.add_rows(session_id, rows, table: @table_name) do
        {:ok, inserted_rows} -> {:ok, length(inserted_rows)}
        {:error, reason} -> {:error, {:insert_failed, reason}}
      end

    restore_source(previous_source)
    result
  end

  defp restore_source(nil), do: Process.delete(:rho_source)
  defp restore_source(source), do: Process.put(:rho_source, source)

  defp row_limit(input) do
    case get(input, :limit) || get(input, :max_results) do
      n when is_integer(n) and n > 0 -> min(n, @default_limit)
      _ -> @default_limit
    end
  end

  defp compact_join(values, joiner) do
    values
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(joiner)
  end

  defp normalize_url(nil), do: nil
  defp normalize_url(url) when is_binary(url), do: url |> String.trim() |> String.downcase()
  defp normalize_url(_), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(values) when is_list(values) do
    values
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> normalize_text()
  end

  defp normalize_text(_), do: nil

  defp get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
