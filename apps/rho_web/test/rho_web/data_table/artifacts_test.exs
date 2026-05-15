defmodule RhoWeb.DataTable.ArtifactsTest do
  use ExUnit.Case, async: true

  alias Rho.Stdlib.DataTable.WorkbenchContext
  alias Rho.Stdlib.DataTable.WorkbenchContext.ArtifactSummary
  alias RhoWeb.DataTable.Artifacts

  test "classifies library and candidate views" do
    assert Artifacts.library_name_from_table("library:Core Skills") == "Core Skills"
    assert Artifacts.library_name_from_table("main") == ""

    assert Artifacts.library_view?(:skill_library, "main")
    assert Artifacts.library_view?("other", "library:Core Skills")
    refute Artifacts.library_view?("other", "main")

    assert Artifacts.candidates_view?(:role_candidates, "main")
    assert Artifacts.candidates_view?("other", "role_candidates")
    refute Artifacts.candidates_view?("other", "main")
  end

  test "extracts active artifacts and artifacts by table" do
    library = artifact(table_name: "library:Core", title: "Core")
    role = artifact(table_name: "role:Principal", title: "Principal")
    context = %WorkbenchContext{active_artifact: library, artifacts: [library, role]}

    assert Artifacts.active_artifact(context) == library
    assert Artifacts.artifact_for_table(context, "role:Principal") == role
    assert Artifacts.artifact_for_table(context, "missing") == nil
    assert Artifacts.active_artifact(nil) == nil
  end

  test "detects empty workbench home state" do
    empty_main = artifact(table_name: "main", row_count: 0)

    context = %WorkbenchContext{
      active_table: "main",
      active_artifact: empty_main,
      artifacts: [empty_main]
    }

    assert Artifacts.workbench_home?(context, ["main"], "main", [])
    refute Artifacts.workbench_home?(context, ["main", "library:Core"], "main", [])
    refute Artifacts.workbench_home?(context, ["main"], "main", [%{id: "1"}])
  end

  test "delegates labels and metrics while preserving fallbacks" do
    assert Artifacts.tab_label(nil, "main") == "Scratch Table"
    assert Artifacts.kind_label(nil, "Data") == "Data"
    assert Artifacts.metric_labels(nil, 3) == ["3 rows"]
    assert Artifacts.surface(nil) == :artifact_summary

    artifact =
      artifact(
        kind: :skill_library,
        title: "Core",
        subtitle: "Editable",
        metrics: %{skills: 2, categories: 1, proficiency_levels: 4}
      )

    assert Artifacts.title(artifact, "Fallback") == "Core"
    assert Artifacts.subtitle(artifact, "Fallback") == "Editable"
    assert Artifacts.kind_label(artifact, "Fallback") == "Skill framework"
    assert "2 skills" in Artifacts.metric_labels(artifact, 0)
    assert Artifacts.selection_noun(artifact, 1) == "skill"
  end

  test "normalizes surface notices and linked summaries" do
    artifact =
      artifact(
        linked: %{
          linked_library_table: "library:Core",
          linked_role_table: "role:Principal",
          source_upload_id: nil
        },
        metrics: %{unresolved: 1},
        row_count: 7
      )

    assert Artifacts.surface_notice?(:linked_artifacts)
    refute Artifacts.surface_notice?(:artifact_summary)
    assert Artifacts.surface_metrics(artifact) == %{unresolved: 1, rows: 7}
    assert Artifacts.linked_summary(artifact) == "skill framework, role requirements"
  end

  defp artifact(attrs) do
    struct!(ArtifactSummary, attrs)
  end
end
