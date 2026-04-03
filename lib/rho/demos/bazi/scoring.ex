defmodule Rho.Demos.Bazi.Scoring do
  @moduledoc """
  Pure computation module for aggregating and scoring Bazi advisor proposals.

  No external dependencies — no Comms, no Worker. All functions are deterministic
  transformations over score maps keyed by `{role_atom, round_int}`.
  """

  @doc """
  Merges dimension proposals from multiple advisors.

  Flattens all proposed dimensions, counts frequency across advisors, sorts
  descending by frequency, and returns the top 5.

  ## Examples

      iex> Scoring.merge_dimensions(%{advisor_a: ["财运", "事业发展"], advisor_b: ["财运", "健康"]})
      ["财运", "事业发展", "健康"]
  """
  @spec merge_dimensions(%{atom() => [String.t()]}) :: [String.t()]
  def merge_dimensions(proposals) when map_size(proposals) == 0, do: []

  def merge_dimensions(proposals) do
    proposals
    |> Map.values()
    |> List.flatten()
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_dim, count} -> count end, :desc)
    |> Enum.map(fn {dim, _count} -> dim end)
    |> Enum.take(5)
  end

  @doc """
  Aggregates scores across all advisors for a given round.

  For each option, computes per-dimension averages across all advisors, then
  a composite score (average of all dimension averages). Excludes "rationale".

  Returns `%{option => %{dim => avg, "composite" => avg}}`.
  """
  @spec aggregate_scores(%{{atom(), integer()} => map()}, integer()) :: map()
  def aggregate_scores(scores, round) do
    round_entries =
      scores
      |> Enum.filter(fn {{_role, r}, _v} -> r == round end)
      |> Enum.map(fn {_key, option_map} -> option_map end)

    # Collect all options
    all_options =
      round_entries
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    Map.new(all_options, fn option ->
      # Gather this option's score maps from each advisor
      advisor_score_maps =
        round_entries
        |> Enum.filter(&Map.has_key?(&1, option))
        |> Enum.map(&Map.get(&1, option))

      dim_avgs = compute_dim_averages(advisor_score_maps)

      composite =
        if map_size(dim_avgs) == 0 do
          0
        else
          dim_avgs
          |> Map.values()
          |> then(fn vals -> round(Enum.sum(vals) / length(vals)) end)
        end

      {option, Map.put(dim_avgs, "composite", composite)}
    end)
  end

  @doc """
  Builds a human-readable summary of scoring disagreements for a given round.

  A disagreement is when the spread (max - min) across advisors exceeds 20 points
  for a given option+dimension pair.

  Returns a newline-joined string, or "" if no disagreements exist.

  Format: "选项A · 财运: 分歧30分 (bazi_advisor_qwen: 50, bazi_advisor_deepseek: 80)"
  """
  @spec build_disagreement_summary(%{{atom(), integer()} => map()}, integer()) :: String.t()
  def build_disagreement_summary(scores, round) do
    round_keyed =
      scores
      |> Enum.filter(fn {{_role, r}, _v} -> r == round end)

    all_options =
      round_keyed
      |> Enum.flat_map(fn {_k, opt_map} -> Map.keys(opt_map) end)
      |> Enum.uniq()

    all_dims =
      round_keyed
      |> Enum.flat_map(fn {_k, opt_map} ->
        opt_map
        |> Map.values()
        |> Enum.flat_map(fn dim_map ->
          dim_map |> Map.keys() |> Enum.reject(&(&1 == "rationale"))
        end)
      end)
      |> Enum.uniq()

    lines =
      for option <- all_options,
          dim <- all_dims do
        # Collect {role, score} pairs for this option+dim
        role_scores =
          round_keyed
          |> Enum.filter(fn {{_role, _r}, opt_map} -> Map.has_key?(opt_map, option) end)
          |> Enum.flat_map(fn {{role, _r}, opt_map} ->
            case get_in(opt_map, [option, dim]) do
              nil -> []
              val -> [{role, val}]
            end
          end)

        if length(role_scores) < 2 do
          nil
        else
          vals = Enum.map(role_scores, fn {_r, v} -> v end)
          spread = Enum.max(vals) - Enum.min(vals)

          if spread > 20 do
            detail =
              role_scores
              |> Enum.map(fn {role, score} -> "#{role}: #{score}" end)
              |> Enum.join(", ")

            "#{option} · #{dim}: 分歧#{spread}分 (#{detail})"
          else
            nil
          end
        end
      end

    lines
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Computes per-dimension score deltas between round 1 and round 2 for a specific role.

  Returns `%{option => %{dim => delta}}` where positive means increased, negative decreased.
  Excludes "rationale".
  """
  @spec compute_deltas(%{{atom(), integer()} => map()}, atom()) :: map()
  def compute_deltas(scores, role) do
    round1 = Map.get(scores, {role, 1}, %{})
    round2 = Map.get(scores, {role, 2}, %{})

    all_options =
      (Map.keys(round1) ++ Map.keys(round2))
      |> Enum.uniq()

    Map.new(all_options, fn option ->
      dims1 = Map.get(round1, option, %{}) |> Map.drop(["rationale"])
      dims2 = Map.get(round2, option, %{}) |> Map.drop(["rationale"])

      all_dims = (Map.keys(dims1) ++ Map.keys(dims2)) |> Enum.uniq()

      dim_deltas =
        Map.new(all_dims, fn dim ->
          v1 = Map.get(dims1, dim, 0)
          v2 = Map.get(dims2, dim, 0)
          {dim, v2 - v1}
        end)

      {option, dim_deltas}
    end)
  end

  @doc """
  Formats scores for a given round as a markdown table.

  One section per option, rows = advisors, columns = dimensions + composite.
  """
  @spec format_score_table(%{{atom(), integer()} => map()}, integer(), [String.t()]) :: String.t()
  def format_score_table(scores, round, dimensions) do
    round_keyed =
      scores
      |> Enum.filter(fn {{_role, r}, _v} -> r == round end)

    all_options =
      round_keyed
      |> Enum.flat_map(fn {_k, opt_map} -> Map.keys(opt_map) end)
      |> Enum.uniq()
      |> Enum.sort()

    header_cols = dimensions ++ ["composite"]
    header = "| 顾问 | " <> Enum.join(header_cols, " | ") <> " |"
    separator = "| --- |" <> String.duplicate(" --- |", length(header_cols))

    sections =
      Enum.map(all_options, fn option ->
        rows =
          round_keyed
          |> Enum.filter(fn {{_role, _r}, opt_map} -> Map.has_key?(opt_map, option) end)
          |> Enum.map(fn {{role, _r}, opt_map} ->
            dim_map = Map.get(opt_map, option, %{})
            dim_scores = Enum.map(dimensions, fn d -> Map.get(dim_map, d, "-") end)

            numeric_scores =
              dim_scores
              |> Enum.filter(&is_number/1)

            composite =
              if length(numeric_scores) > 0 do
                round(Enum.sum(numeric_scores) / length(numeric_scores))
              else
                "-"
              end

            cols = dim_scores ++ [composite]
            "| #{format_role(role)} | " <> Enum.map_join(cols, " | ", &to_string/1) <> " |"
          end)

        ["### #{option}", header, separator] ++ rows
      end)

    sections
    |> List.flatten()
    |> Enum.join("\n")
  end

  # --- Private helpers ---

  defp compute_dim_averages(advisor_score_maps) do
    all_dims =
      advisor_score_maps
      |> Enum.flat_map(fn m -> m |> Map.keys() |> Enum.reject(&(&1 == "rationale")) end)
      |> Enum.uniq()

    Map.new(all_dims, fn dim ->
      vals =
        advisor_score_maps
        |> Enum.flat_map(fn m ->
          case Map.get(m, dim) do
            nil -> []
            v when is_number(v) -> [v]
            _ -> []
          end
        end)

      avg = if length(vals) > 0, do: round(Enum.sum(vals) / length(vals)), else: 0
      {dim, avg}
    end)
  end

  @doc false
  def format_role(:bazi_advisor_qwen), do: "Qwen"
  def format_role(:bazi_advisor_deepseek), do: "DeepSeek"
  def format_role(:bazi_advisor_gpt), do: "GPT-5.4"
  def format_role(role), do: role |> to_string() |> String.replace("bazi_advisor_", "") |> String.capitalize()
end
