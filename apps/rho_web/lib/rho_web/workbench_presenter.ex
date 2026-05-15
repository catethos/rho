defmodule RhoWeb.WorkbenchPresenter do
  @moduledoc """
  Web-only presentation helpers for DataTable workbench artifacts.

  `Rho.Stdlib.DataTable.WorkbenchContext` owns pure artifact derivation. This
  module maps that semantic summary into labels, metric chips, and trusted
  surface variants that Phoenix components may render.
  """

  alias Rho.Stdlib.DataTable.WorkbenchContext.ArtifactSummary

  @surface_catalog MapSet.new([
                     :artifact_summary,
                     :linked_artifacts,
                     :role_candidate_picker,
                     :conflict_review,
                     :dedup_review,
                     :gap_review,
                     :confirmation_panel
                   ])

  @action_labels %{
    save_draft: "Save draft",
    generate_levels: "Generate levels",
    suggest_skills: "Suggest skills",
    publish: "Publish",
    export: "Export",
    fork: "Fork",
    dedup: "Deduplicate",
    save_role_profile: "Save role profile",
    map_to_framework: "Map to framework",
    review_gaps: "Review gaps",
    seed_framework_from_selected: "Seed framework",
    clone_selected_role: "Clone role",
    clear_selection: "Clear selection",
    resolve_conflicts: "Resolve conflicts",
    create_merged_library: "Create merged library",
    resolve_duplicates: "Resolve duplicates",
    apply_cleanup: "Apply cleanup",
    save_cleaned_framework: "Save cleaned framework",
    export_review: "Export review",
    review_findings: "Review findings",
    apply_recommendations: "Apply recommendations"
  }

  def title(%ArtifactSummary{title: title}, _fallback) when is_binary(title), do: title
  def title(_, fallback), do: fallback

  def subtitle(%ArtifactSummary{subtitle: subtitle}, _fallback) when is_binary(subtitle),
    do: subtitle

  def subtitle(_, fallback) when is_binary(fallback), do: fallback
  def subtitle(_, _), do: "Editable data artifact"

  def tab_label(%ArtifactSummary{title: title}, _fallback) when is_binary(title), do: title
  def tab_label(_, fallback), do: fallback

  def tab_meta(%ArtifactSummary{kind: :skill_library, metrics: metrics}, _count),
    do: count_label(metrics[:skills] || 0, "skill", "skills")

  def tab_meta(%ArtifactSummary{kind: :role_profile, metrics: metrics}, _count),
    do: count_label(metrics[:required_skills] || 0, "required skill", "required skills")

  def tab_meta(%ArtifactSummary{kind: :role_candidates, metrics: metrics}, _count) do
    selected = metrics[:selected] || 0

    if selected > 0 do
      "#{selected} selected"
    else
      count_label(metrics[:candidates] || 0, "candidate", "candidates")
    end
  end

  def tab_meta(%ArtifactSummary{kind: kind, metrics: metrics}, _count)
      when kind in [:combine_preview, :dedup_preview, :analysis_result] do
    unresolved = metrics[:unresolved] || 0

    if unresolved > 0 do
      "#{unresolved} unresolved"
    else
      "#{metrics[:resolved] || 0} resolved"
    end
  end

  def tab_meta(_artifact, count), do: count_label(count || 0, "row", "rows")

  def kind_label(%ArtifactSummary{kind: :skill_library}), do: "Skill framework"
  def kind_label(%ArtifactSummary{kind: :role_profile}), do: "Role requirements"
  def kind_label(%ArtifactSummary{kind: :role_candidates}), do: "Role picker"
  def kind_label(%ArtifactSummary{kind: :combine_preview}), do: "Conflict review"
  def kind_label(%ArtifactSummary{kind: :dedup_preview}), do: "Duplicate review"
  def kind_label(%ArtifactSummary{kind: :analysis_result}), do: "Analysis review"
  def kind_label(_), do: "Data artifact"

  def metric_labels(%ArtifactSummary{kind: :skill_library, metrics: metrics}) do
    [
      count_label(metrics[:skills] || 0, "skill", "skills"),
      count_label(metrics[:categories] || 0, "category", "categories"),
      count_label(metrics[:proficiency_levels] || 0, "level", "levels"),
      count_label(metrics[:missing_levels] || 0, "need level", "need levels")
    ]
  end

  def metric_labels(%ArtifactSummary{kind: :role_profile, metrics: metrics}) do
    [
      count_label(metrics[:required_skills] || 0, "required skill", "required skills"),
      "#{metrics[:required] || 0} required",
      "#{metrics[:optional] || 0} optional",
      count_label(metrics[:missing_required_levels] || 0, "missing level", "missing levels")
    ]
  end

  def metric_labels(%ArtifactSummary{kind: :role_candidates, metrics: metrics}) do
    [
      count_label(metrics[:candidates] || 0, "candidate", "candidates"),
      count_label(metrics[:queries] || 0, "query", "queries"),
      "#{metrics[:selected] || 0} selected"
    ]
  end

  def metric_labels(%ArtifactSummary{kind: kind, metrics: metrics})
      when kind in [:combine_preview, :dedup_preview] do
    base = [
      count_label(metrics[:pairs] || 0, "pair", "pairs"),
      "#{metrics[:unresolved] || 0} unresolved",
      "#{metrics[:resolved] || 0} resolved"
    ]

    if is_integer(metrics[:clean]), do: base ++ ["#{metrics[:clean]} clean"], else: base
  end

  def metric_labels(%ArtifactSummary{kind: :analysis_result, metrics: metrics}) do
    [
      count_label(metrics[:recommendations] || 0, "recommendation", "recommendations"),
      "#{metrics[:high_priority] || 0} high priority",
      "#{metrics[:unresolved] || 0} unresolved"
    ]
  end

  def metric_labels(%ArtifactSummary{row_count: row_count}),
    do: [count_label(row_count, "row", "rows")]

  def metric_labels(_), do: []

  def selection_noun(%ArtifactSummary{kind: :skill_library}, 1), do: "skill"
  def selection_noun(%ArtifactSummary{kind: :skill_library}, _), do: "skills"
  def selection_noun(%ArtifactSummary{kind: :role_profile}, 1), do: "required skill"
  def selection_noun(%ArtifactSummary{kind: :role_profile}, _), do: "required skills"
  def selection_noun(%ArtifactSummary{kind: :role_candidates}, 1), do: "candidate"
  def selection_noun(%ArtifactSummary{kind: :role_candidates}, _), do: "candidates"
  def selection_noun(_, 1), do: "row"
  def selection_noun(_, _), do: "rows"

  def action_label(action), do: Map.get(@action_labels, action, humanize(action))

  def action_labels(%ArtifactSummary{actions: actions}) when is_list(actions) do
    Enum.map(actions, &action_label/1)
  end

  def action_labels(_), do: []

  @doc "Return a trusted surface kind. Unknown or malformed requests fall back."
  def surface(%ArtifactSummary{surface: %{surface: requested}, kind: kind}) do
    requested
    |> normalize_surface()
    |> fallback_surface(kind)
  end

  def surface(%ArtifactSummary{kind: :role_candidates}), do: :role_candidate_picker
  def surface(%ArtifactSummary{kind: :combine_preview}), do: :conflict_review
  def surface(%ArtifactSummary{kind: :dedup_preview}), do: :dedup_review
  def surface(%ArtifactSummary{kind: :analysis_result}), do: :gap_review
  def surface(%ArtifactSummary{linked: linked}) when map_size(linked) > 0, do: :linked_artifacts
  def surface(%ArtifactSummary{}), do: :artifact_summary
  def surface(_), do: :artifact_summary

  defp fallback_surface(nil, kind), do: surface(%ArtifactSummary{kind: kind})
  defp fallback_surface(surface, _kind), do: surface

  defp normalize_surface(surface) when is_atom(surface) do
    if MapSet.member?(@surface_catalog, surface), do: surface
  end

  defp normalize_surface(surface) when is_binary(surface) do
    surface
    |> String.to_existing_atom()
    |> normalize_surface()
  rescue
    ArgumentError -> nil
  end

  defp normalize_surface(_), do: nil

  defp count_label(1, singular, _plural), do: "1 #{singular}"
  defp count_label(count, _singular, plural), do: "#{count} #{plural}"

  defp humanize(action) do
    action
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
