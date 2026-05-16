defmodule RhoFrameworks.ExaClient do
  @moduledoc """
  Small Exa search client for framework-domain research.

  Returns parsed result maps so use cases do not need to know Exa's wire
  shape. The HTTP boundary stays here; callers can replace the module via
  `:rho_frameworks, :exa_client` in tests.
  """

  @endpoint "https://api.exa.ai/search"
  @default_num_results 5
  @max_num_results 10
  @default_timeout 15_000

  @type result :: %{
          optional(:url) => String.t() | nil,
          optional(:title) => String.t() | nil,
          optional(:summary) => String.t() | nil,
          optional(:highlights) => [String.t()],
          optional(:published_date) => String.t() | nil,
          optional(:author) => String.t() | nil,
          optional(:score) => number() | nil
        }

  @spec search(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    with {:ok, api_key} <- fetch_api_key(),
         {:ok, results} <- post_search(api_key, query, opts) do
      {:ok, Enum.map(results, &parse_result/1)}
    end
  end

  defp fetch_api_key do
    case System.get_env("EXA_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :no_api_key}
    end
  end

  defp post_search(api_key, query, opts) do
    num_results =
      opts
      |> Keyword.get(:num_results, @default_num_results)
      |> normalize_num_results()

    body = %{
      query: query,
      numResults: num_results,
      type: "auto",
      contents: %{
        summary: %{query: Keyword.get(opts, :summary_query, query)}
      }
    }

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", api_key}
    ]

    case Req.post(@endpoint,
           json: body,
           headers: headers,
           receive_timeout: Keyword.get(opts, :timeout, @default_timeout)
         ) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, results}

      {:ok, %{status: 200, body: body}} ->
        {:error, {:exa_failed, {:unexpected_body, body}}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:exa_failed, {:http_error, status, body}}}

      {:error, reason} ->
        {:error, {:exa_failed, reason}}
    end
  end

  defp normalize_num_results(n) when is_integer(n) and n > 0, do: min(n, @max_num_results)
  defp normalize_num_results(_), do: @default_num_results

  defp parse_result(result) when is_map(result) do
    %{
      url: get(result, "url"),
      title: get(result, "title"),
      summary: get_summary(result),
      highlights: get_highlights(result),
      published_date: get(result, "publishedDate") || get(result, "published_date"),
      author: get(result, "author"),
      score: get(result, "score")
    }
  end

  defp get_summary(result) do
    case get(result, "summary") do
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _ -> nil
    end
  end

  defp get_highlights(result) do
    case get(result, "highlights") do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp atom_key("url"), do: :url
  defp atom_key("title"), do: :title
  defp atom_key("summary"), do: :summary
  defp atom_key("highlights"), do: :highlights
  defp atom_key("publishedDate"), do: :publishedDate
  defp atom_key("published_date"), do: :published_date
  defp atom_key("author"), do: :author
  defp atom_key("score"), do: :score
  defp atom_key(_), do: nil
end
