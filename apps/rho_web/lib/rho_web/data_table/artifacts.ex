defmodule RhoWeb.DataTable.Artifacts do
  @moduledoc """
  Presentation helpers for DataTable workbench artifacts.

  The LiveComponent owns events and markup; this module owns the pure mapping
  from table/workbench state to labels, surfaces, counts, and view flags.
  """

  alias Rho.Stdlib.DataTable.WorkbenchContext
  alias RhoWeb.WorkbenchPresenter

  @doc "Returns the display name encoded by a persisted library table name."
  def library_name_from_table("library:" <> name), do: name
  def library_name_from_table(_), do: ""

  @doc "Returns whether the active table/view should expose library actions."
  def library_view?(view_key, active_table) do
    view_key in [:skill_library, "skill_library"] or
      (is_binary(active_table) and String.starts_with?(active_table, "library:"))
  end

  @doc "Returns whether the active table/view is the role candidate picker."
  def candidates_view?(view_key, active_table) do
    view_key in [:role_candidates, "role_candidates"] or active_table == "role_candidates"
  end

  @doc "Returns the active artifact summary from a workbench context."
  def active_artifact(%WorkbenchContext{active_artifact: artifact}), do: artifact
  def active_artifact(_), do: nil

  @doc "Returns whether the empty workbench home state should be rendered."
  def workbench_home?(
        %WorkbenchContext{active_artifact: artifact, artifacts: artifacts},
        order,
        active,
        rows
      ) do
    no_non_main_tables? = no_non_main_tables?(order)

    no_artifacts? =
      artifacts in [nil, []] or
        Enum.all?(artifacts, &(empty_main_artifact?(&1) or row_count(&1) == 0))

    active_main? =
      active in [nil, "main"] or is_nil(artifact) or empty_main_artifact?(artifact) or
        row_count(artifact) == 0

    empty? = Enum.empty?(rows || []) and row_count(artifact) == 0

    no_non_main_tables? and no_artifacts? and active_main? and empty?
  end

  def workbench_home?(_, order, active, rows) do
    no_non_main_tables?(order) and active in [nil, "main"] and Enum.empty?(rows || [])
  end

  @doc "Finds the artifact summary for a table name."
  def artifact_for_table(%WorkbenchContext{artifacts: artifacts}, table_name) do
    Enum.find(artifacts, &(&1.table_name == table_name))
  end

  def artifact_for_table(_, _), do: nil

  @doc "Returns a human label for an artifact tab."
  def tab_label(nil, "main"), do: "Scratch Table"
  def tab_label(artifact, fallback), do: WorkbenchPresenter.tab_label(artifact, fallback)

  @doc "Returns tab metadata such as row counts."
  def tab_meta(artifact, count), do: WorkbenchPresenter.tab_meta(artifact, count)

  @doc "Returns the main artifact title."
  def title(artifact, fallback), do: WorkbenchPresenter.title(artifact, fallback)

  @doc "Returns the artifact subtitle."
  def subtitle(artifact, fallback), do: WorkbenchPresenter.subtitle(artifact, fallback)

  @doc "Returns the artifact kind/kicker label."
  def kind_label(nil, fallback), do: fallback
  def kind_label(artifact, _fallback), do: WorkbenchPresenter.kind_label(artifact)

  @doc "Returns metric pill labels for the artifact header."
  def metric_labels(nil, row_count), do: ["#{row_count} rows"]
  def metric_labels(artifact, _row_count), do: WorkbenchPresenter.metric_labels(artifact)

  @doc "Returns the selected-row noun for an artifact."
  def selection_noun(artifact, count), do: WorkbenchPresenter.selection_noun(artifact, count)

  @doc "Returns the artifact surface type."
  def surface(nil), do: :artifact_summary
  def surface(artifact), do: WorkbenchPresenter.surface(artifact)

  @doc "Returns whether the surface has a notice panel."
  def surface_notice?(surface) do
    surface in [
      :linked_artifacts,
      :role_candidate_picker,
      :conflict_review,
      :dedup_review,
      :gap_review
    ]
  end

  @doc "Returns surface metrics normalized with a row count."
  def surface_metrics(%WorkbenchContext.ArtifactSummary{metrics: metrics, row_count: row_count}) do
    Map.put(metrics || %{}, :rows, row_count || 0)
  end

  def surface_metrics(_), do: %{}

  @doc "Summarizes linked artifacts in a compact notice string."
  def linked_summary(%WorkbenchContext.ArtifactSummary{linked: linked}) do
    labels =
      []
      |> maybe_linked_label("skill framework", linked[:linked_library_table])
      |> maybe_linked_label("role requirements", linked[:linked_role_table])
      |> maybe_linked_label("source upload", linked[:source_upload_id])
      |> maybe_linked_label("source libraries", linked[:source_library_ids])
      |> maybe_linked_label("source roles", linked[:source_role_profile_ids])

    case labels do
      [] -> "Related artifacts are available in the artifact strip."
      labels -> Enum.join(Enum.reverse(labels), ", ")
    end
  end

  def linked_summary(_), do: "Related artifacts are available in the artifact strip."

  defp no_non_main_tables?(order) do
    case order do
      [] -> true
      list when is_list(list) -> Enum.all?(list, &(&1 == "main"))
      _ -> true
    end
  end

  defp row_count(%{row_count: count}) when is_integer(count), do: count
  defp row_count(_), do: 0

  defp empty_main_artifact?(%{table_name: table_name, row_count: count}) do
    table_name in [nil, "main"] and count in [nil, 0]
  end

  defp empty_main_artifact?(_), do: false

  defp maybe_linked_label(labels, _label, value) when value in [nil, "", []], do: labels
  defp maybe_linked_label(labels, label, _value), do: [label | labels]
end
