defmodule Rho.Stdlib.Uploads.Observer.Hints do
  @moduledoc """
  Column-detection algorithm. Maps normalized header strings to library
  schema columns. The original header value is preserved in the hint —
  Layer 3 uses it to read raw cells.
  """

  @aliases %{
    library_name_column: ["skill library name", "library name", "library", "framework name"],
    role_column: ["role", "role name", "job role", "position"],
    skill_name_column: ["skill name", "skill", "competency", "competence"],
    skill_description_column: [
      "skill description",
      "description",
      "definition",
      "what it means"
    ],
    category_column: ["category", "domain", "area", "group"],
    cluster_column: ["cluster", "sub-category", "sub-domain", "subgroup"],
    level_column: ["level", "proficiency level", "tier"],
    level_name_column: ["level name", "tier name"],
    level_description_column: ["level description", "tier description", "indicator"]
  }

  @doc """
  Build hints from a list of sheet summaries `[%{name, columns, ...}]`.
  Returns a map matching `Observation.hints` shape.
  """
  def from_sheets(sheets) when is_list(sheets) do
    # Use the first non-empty sheet's columns for column-level hints.
    cols =
      sheets
      |> Enum.find(fn %{columns: c} -> c != [] end)
      |> case do
        nil -> []
        %{columns: c} -> c
      end

    base = Map.new(@aliases, fn {k, _} -> {k, match_column(cols, @aliases[k])} end)
    Map.put(base, :sheet_strategy, derive_strategy(sheets, base))
  end

  defp match_column(cols, aliases) do
    cols
    |> Enum.find(fn header ->
      normalized = normalize(header)
      Enum.any?(aliases, &(&1 == normalized))
    end)
  end

  defp normalize(header) do
    header
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9 ]+/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp derive_strategy([_one], %{library_name_column: _}), do: :single_library

  defp derive_strategy([_one], _hints), do: :single_library

  defp derive_strategy([_, _ | _] = sheets, %{library_name_column: nil}) do
    if all_same_columns?(sheets) do
      :roles_per_sheet
    else
      :ambiguous
    end
  end

  defp derive_strategy([_, _ | _], _hints), do: :single_library

  defp derive_strategy(_, _), do: :ambiguous

  defp all_same_columns?(sheets) do
    sheets
    |> Enum.map(&MapSet.new(&1.columns))
    |> Enum.uniq()
    |> length() == 1
  end
end
