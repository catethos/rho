defmodule Rho.Stdlib.Tools.SearchHistory do
  @moduledoc "Tool for searching conversation history across all phases."

  def tool_def(tape_name) do
    %{
      tool:
        ReqLLM.tool(
          name: "search_history",
          description:
            "Search past conversation messages by keyword, including messages from before " <>
              "the current phase (before anchors). Use when the user references something " <>
              "discussed earlier that is no longer in the current context window.",
          parameter_schema: [
            query: [type: :string, required: true, doc: "Keyword or phrase to search for"],
            limit: [type: :integer, doc: "Max results to return (default: 10)"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx -> execute(args, tape_name) end
    }
  end

  defp execute(args, tape_name) do
    query = args[:query] || ""
    limit = args[:limit] || 10

    if String.trim(query) == "" do
      {:error, "query is required"}
    else
      results = Rho.Tape.Service.search(tape_name, query, limit)
      format_search_results(results, query)
    end
  end

  defp format_search_results([], query) do
    {:ok, "No messages found matching \"#{query}\"."}
  end

  defp format_search_results(results, _query) do
    formatted =
      Enum.map_join(results, "\n---\n", fn entry ->
        role = entry.payload["role"] || "unknown"
        content = entry.payload["content"] || ""
        "[#{role}] #{content}"
      end)

    {:ok, "Found #{length(results)} result(s):\n#{formatted}"}
  end
end
