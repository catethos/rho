defmodule RhoWeb.WorkbenchActionRunnerTest do
  use ExUnit.Case, async: true

  alias RhoWeb.WorkbenchActionRunner

  test "builds a structured create framework prompt" do
    prompt =
      WorkbenchActionRunner.build_prompt(:create_framework, %{
        "name" => "Product Manager",
        "description" => "Owns product outcomes",
        "domain" => "Product",
        "target_roles" => "PM, Senior PM",
        "skill_count" => "12"
      })

    assert prompt =~ "Call generate_framework_skeletons with:"
    assert prompt =~ "- name: Product Manager"
    assert prompt =~ "- skill_count: 12"
    assert prompt =~ "keep it open in the Workbench"
  end

  test "builds extract and import prompts around upload ids" do
    extract =
      WorkbenchActionRunner.build_prompt(:extract_jd, %{
        "upload_id" => "upl_1",
        "role_name" => "Designer"
      })

    import =
      WorkbenchActionRunner.build_prompt(:import_library, %{
        "upload_id" => "upl_2",
        "library_name" => "Design",
        "sheet" => "Skills"
      })

    assert extract =~ "Use extract_role_from_jd"
    assert extract =~ "- upload_id: upl_1"
    assert import =~ "Use import_library_from_upload"
    assert import =~ "- sheet: Skills"
  end

  test "normalizes role queries and metadata" do
    params = %{"queries" => "Designer\nProduct Manager,Engineer", "limit" => "50"}

    assert WorkbenchActionRunner.role_queries(params) == [
             "Designer",
             "Product Manager",
             "Engineer"
           ]

    assert WorkbenchActionRunner.role_limit(params) == 25

    metadata =
      WorkbenchActionRunner.role_candidates_metadata(
        [%{query: "Designer", count: 2}],
        2,
        ["Designer"]
      )

    assert metadata.artifact_kind == :role_candidates
    assert metadata.ui_intent.surface == :role_candidate_picker
  end

  test "validates create role profile requires a source library and role name" do
    assert {:error, "Choose a source library."} =
             WorkbenchActionRunner.validate(:create_role_profile, %{})

    assert {:error, "Role name is required."} =
             WorkbenchActionRunner.validate(:create_role_profile, %{"library_id" => "lib-1"})

    assert :ok =
             WorkbenchActionRunner.validate(:create_role_profile, %{
               "library_id" => "lib-1",
               "role_name" => "Backend Engineer"
             })
  end
end
