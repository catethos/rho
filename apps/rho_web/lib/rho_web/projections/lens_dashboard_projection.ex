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

  @handled_kinds MapSet.new(~w(lens_score_update lens_dashboard_init lens_switch)a)

  @impl true
  def handles?(kind), do: kind in @handled_kinds

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
  def reduce(state, %{kind: kind, data: data}) do
    case kind do
      :lens_score_update -> reduce_score_update(state, data)
      :lens_dashboard_init -> reduce_dashboard_init(state, data)
      :lens_switch -> reduce_lens_switch(state, data)
      _ -> state
    end
  end

  defp reduce_dashboard_init(_state, data) do
    lens = Rho.MapAccess.get(data, :lens)
    scores = Rho.MapAccess.get(data, :scores) || []
    summary = Rho.MapAccess.get(data, :summary) || %{}

    scores_map =
      scores
      |> Enum.map(fn s ->
        id = Rho.MapAccess.get(s, :score_id)
        {id, s}
      end)
      |> Map.new()

    %{
      lens: lens,
      scores: scores_map,
      summary: normalize_summary(summary),
      selected_score_id: nil,
      active_lens_slug: Rho.MapAccess.get(lens, :slug)
    }
  end

  defp reduce_score_update(state, data) do
    score = Rho.MapAccess.get(data, :score) || %{}
    score_id = Rho.MapAccess.get(score, :score_id)

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
      total: Rho.MapAccess.get(summary, :total) || 0,
      by_classification: Rho.MapAccess.get(summary, :by_classification) || %{},
      axis_averages: Rho.MapAccess.get(summary, :axis_averages) || []
    }
  end

  defp normalize_summary(_), do: %{total: 0, by_classification: %{}, axis_averages: []}

  # Recompute summary from in-memory scores
  defp recompute_summary(scores, lens) do
    score_list = Map.values(scores)
    total = length(score_list)

    by_classification =
      score_list
      |> Enum.group_by(fn s -> Rho.MapAccess.get(s, :classification) end)
      |> Map.new(fn {label, items} -> {label, length(items)} end)

    axis_averages = compute_axis_averages(score_list, lens)

    %{total: total, by_classification: by_classification, axis_averages: axis_averages}
  end

  defp compute_axis_averages(_scores, nil), do: []

  defp compute_axis_averages(scores, lens) do
    axes = Rho.MapAccess.get(lens, :axes) || []
    Enum.map(axes, fn axis -> compute_single_axis_average(axis, scores) end)
  end

  defp compute_single_axis_average(axis, scores) do
    name = Rho.MapAccess.get(axis, :name)
    short_name = Rho.MapAccess.get(axis, :short_name)
    sort_order = Rho.MapAccess.get(axis, :sort_order)

    composites = collect_composites_for_axis(scores, sort_order)

    avg =
      if composites == [],
        do: 0.0,
        else: Float.round(Enum.sum(composites) / length(composites), 1)

    %{axis_name: name, short_name: short_name, average: avg}
  end

  defp collect_composites_for_axis(scores, sort_order) do
    Enum.flat_map(scores, fn s ->
      (Rho.MapAccess.get(s, :axes) || [])
      |> Enum.filter(fn a -> (Rho.MapAccess.get(a, :sort_order)) == sort_order end)
      |> Enum.map(fn a -> Rho.MapAccess.get(a, :composite) || 0.0 end)
    end)
  end
end
