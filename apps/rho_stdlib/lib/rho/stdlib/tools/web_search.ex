defmodule Rho.Stdlib.Tools.WebSearch do
  @moduledoc "Tool for web search via the Exa API. Returns a ranked list of results — the agent picks URLs to `web_fetch`."

  @behaviour Rho.Plugin

  @endpoint "https://api.exa.ai/search"
  @default_num_results 5
  @max_num_results 25
  @default_timeout 15_000

  @impl Rho.Plugin
  def tools(_mount_opts, _context), do: [tool_def()]

  defp tool_def do
    %{
      tool:
        ReqLLM.tool(
          name: "web_search",
          description:
            "Search the web via Exa and return a ranked list of results " <>
              "(title, URL, published date, short highlights). Pick the most relevant URLs " <>
              "and call `web_fetch` for full content.",
          parameter_schema: [
            query: [type: :string, required: true, doc: "The search query"],
            num_results: [
              type: :integer,
              doc:
                "Number of results to return (default #{@default_num_results}, max #{@max_num_results})"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx -> execute(args) end
    }
  end

  def execute(%{"query" => query} = args) do
    execute(%{query: query, num_results: args["num_results"]})
  end

  def execute(%{query: query} = args) do
    with {:ok, api_key} <- fetch_api_key(),
         num <- normalize_num_results(args[:num_results]),
         {:ok, results} <- post_search(api_key, query, num) do
      {:ok, format_results(query, results)}
    end
  end

  defp fetch_api_key do
    case System.get_env("EXA_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, "EXA_API_KEY environment variable is not set"}
    end
  end

  defp normalize_num_results(nil), do: @default_num_results
  defp normalize_num_results(n) when is_integer(n) and n > 0, do: min(n, @max_num_results)
  defp normalize_num_results(_), do: @default_num_results

  defp post_search(api_key, query, num_results) do
    body = %{
      query: query,
      numResults: num_results,
      type: "auto",
      contents: %{highlights: true}
    }

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", api_key}
    ]

    case Req.post(@endpoint,
           json: body,
           headers: headers,
           receive_timeout: @default_timeout
         ) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, results}

      {:ok, %{status: 200, body: body}} ->
        {:error, "Exa returned 200 with unexpected body: #{inspect(body)}"}

      {:ok, %{status: status, body: body}} ->
        {:error, "Exa search failed (status #{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Exa request failed: #{inspect(reason)}"}
    end
  end

  defp format_results(query, []) do
    "No results for query: #{query}"
  end

  defp format_results(query, results) do
    header = "Search results for: #{query}\n"

    body =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", &format_result/1)

    header <> "\n" <> body
  end

  defp format_result({result, index}) do
    title = result["title"] || "(untitled)"
    url = result["url"] || ""
    published = result["publishedDate"]
    author = result["author"]

    head = "#{index}. #{title}\n   #{url}"

    meta =
      [
        published && "Published: #{published}",
        author && author != "" && "Author: #{author}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == false))

    meta_line = if meta == [], do: "", else: "\n   " <> Enum.join(meta, " · ")

    highlights =
      case result["highlights"] do
        list when is_list(list) and list != [] ->
          "\n" <> Enum.map_join(list, "\n", &("   - " <> trim_highlight(&1)))

        _ ->
          ""
      end

    head <> meta_line <> highlights
  end

  defp trim_highlight(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp trim_highlight(text), do: inspect(text)
end