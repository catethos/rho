defmodule RhoWeb.Projections.LensDashboardProjection do
  @moduledoc """
  Pure reducer that transforms lens scoring signals into dashboard state.

  Operates entirely on plain maps — no `Socket.t()` dependency.
  State shape:
    %{
      lens: map() | nil,
      scores: %{score_id => score_map},
      summary: map(),
      selected_score_id: integer() | nil,
      active_lens_slug: String.t() | nil
    }
  """

  @behaviour RhoWeb.Projection

  @handled_suffixes ~w(
    lens_score_update
    lens_dashboard_init
    lens_switch
  )

  @impl true
  def handles?(type) when is_binary(type) do
    suffix = type |> String.split(".") |> List.last()
    suffix in @handled_suffixes
  end

  @impl true
  def init do
    %{
      lens: nil,
      scores: %{},
      summary: %{total: 0, by_classification: %{}, axis_averages: []},
      selected_score_id: nil,
      active_lens_slug: nil
    }
  end

  @impl true
  def reduce(state, %{type: type, data: data}) do
    suffix = type |> String.split(".") |> List.last()

    case suffix do
      "lens_score_update" -> reduce_score_update(state, data)
      "lens_dashboard_init" -> reduce_dashboard_init(state, data)
      "lens_switch" -> reduce_lens_switch(state, data)
      _ -> state
    end
  end

  defp reduce_dashboard_init(_state, data) do
    lens = data[:lens] || data["lens"]
    scores = data[:scores] || data["scores"] || []
    summary = data[:summary] || data["summary"] || %{}

    scores_map =
      scores
      |> Enum.map(fn s ->
        id = s[:score_id] || s["score_id"]
        {id, s}
      end)
      |> Map.new()

    %{
      lens: lens,
      scores: scores_map,
      summary: normalize_summary(summary),
      selected_score_id: nil,
      active_lens_slug: get_in(lens, [:slug]) || get_in(lens, ["slug"])
    }
  end

  defp reduce_score_update(state, data) do
    score = data[:score] || data["score"] || %{}
    score_id = score[:score_id] || score["score_id"]

    scores = Map.put(state.scores, score_id, score)
    summary = recompute_summary(scores, state.lens)

    %{state | scores: scores, summary: summary}
  end

  defp reduce_lens_switch(_state, data) do
    # Full reset with new lens data
    reduce_dashboard_init(init(), data)
  end

  defp normalize_summary(summary) when is_map(summary) do
    %{
      total: summary[:total] || summary["total"] || 0,
      by_classification: summary[:by_classification] || summary["by_classification"] || %{},
      axis_averages: summary[:axis_averages] || summary["axis_averages"] || []
    }
  end

  defp normalize_summary(_), do: %{total: 0, by_classification: %{}, axis_averages: []}

  # Recompute summary from in-memory scores
  defp recompute_summary(scores, lens) do
    score_list = Map.values(scores)
    total = length(score_list)

    by_classification =
      score_list
      |> Enum.group_by(fn s -> s[:classification] || s["classification"] end)
      |> Map.new(fn {label, items} -> {label, length(items)} end)

    axis_averages = compute_axis_averages(score_list, lens)

    %{total: total, by_classification: by_classification, axis_averages: axis_averages}
  end

  defp compute_axis_averages(_scores, nil), do: []

  defp compute_axis_averages(scores, lens) do
    axes = lens[:axes] || lens["axes"] || []
    Enum.map(axes, fn axis -> compute_single_axis_average(axis, scores) end)
  end

  defp compute_single_axis_average(axis, scores) do
    name = axis[:name] || axis["name"]
    short_name = axis[:short_name] || axis["short_name"]
    sort_order = axis[:sort_order] || axis["sort_order"]

    composites = collect_composites_for_axis(scores, sort_order)

    avg =
      if composites == [],
        do: 0.0,
        else: Float.round(Enum.sum(composites) / length(composites), 1)

    %{axis_name: name, short_name: short_name, average: avg}
  end

  defp collect_composites_for_axis(scores, sort_order) do
    Enum.flat_map(scores, fn s ->
      (s[:axes] || s["axes"] || [])
      |> Enum.filter(fn a -> (a[:sort_order] || a["sort_order"]) == sort_order end)
      |> Enum.map(fn a -> a[:composite] || a["composite"] || 0.0 end)
    end)
  end
end
