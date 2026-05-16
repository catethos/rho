defmodule RhoFrameworks.UseCases.ResearchDomain.Mapper do
  @moduledoc "Pure Exa result to `research_notes` row mapping."

  @spec to_row(map()) :: map() | nil
  def to_row(result) when is_map(result) do
    source = text(result, :url)
    fact = first_text([text(result, :summary), first_highlight(result), text(result, :title)])

    if source && fact do
      %{
        source: source,
        source_title: text(result, :title),
        fact: fact,
        tag: nil,
        published_date: text(result, :published_date),
        relevance: relevance(result),
        pinned: true
      }
    end
  end

  def to_row(_), do: nil

  defp first_highlight(result) do
    result
    |> value(:highlights)
    |> case do
      [head | _] -> clean(head)
      _ -> nil
    end
  end

  defp first_text(values) do
    values
    |> Enum.map(&clean/1)
    |> Enum.find(& &1)
  end

  defp text(map, key), do: map |> value(key) |> clean()

  defp relevance(result) do
    case value(result, :score) do
      score when is_float(score) -> Float.round(score, 3)
      score when is_integer(score) -> score
      _ -> nil
    end
  end

  defp value(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp clean(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp clean(_), do: nil
end
