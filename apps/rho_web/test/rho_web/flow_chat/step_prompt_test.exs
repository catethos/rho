defmodule RhoWeb.FlowChat.StepPromptTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.FlowRunner
  alias RhoFrameworks.Flows.CreateFramework
  alias RhoWeb.FlowChat.StepPrompt

  test "builds a compact prompt from current flow metadata and runner context" do
    runner =
      FlowRunner.init(CreateFramework,
        start: :save,
        intake: %{
          name: "Backend Engineering",
          description: "Skills for backend engineers",
          taxonomy_size: "balanced",
          transferability: "mixed",
          specificity: "general",
          levels: "5"
        },
        summaries: %{
          generate_skills: %{table_name: "library:Backend Engineering", library_id: "lib-1"}
        }
      )

    step = FlowRunner.current_node(runner)

    prompt =
      StepPrompt.build(CreateFramework, runner,
        step: step,
        tool_names: ["save_framework", "clarify"],
        table_name: "library:Backend Engineering"
      )

    assert prompt =~ "Current step: save"
    assert prompt =~ "Step label: Save to Library"
    assert prompt =~ "Step type: action"
    assert prompt =~ "Allowed tools:"
    assert prompt =~ "- save_framework"
    assert prompt =~ "- clarify"
    assert prompt =~ "Framework name: Backend Engineering"
    assert prompt =~ "Description: Skills for backend engineers"
    assert prompt =~ "Structure size: balanced"
    assert prompt =~ "Library table: library:Backend Engineering"
    assert prompt =~ "Stay inside this step"
    assert prompt =~ "Never run more than one tool per turn"
  end

  test "describes allowed choices and selected role artifacts for decision steps" do
    runner =
      FlowRunner.init(CreateFramework, start: :role_transform)
      |> FlowRunner.put_summary(:similar_roles, %{
        selected: [%{id: "role-1", name: "Risk Analyst"}]
      })

    step = FlowRunner.current_node(runner)
    prompt = StepPrompt.build(CreateFramework, runner, step: step)

    assert prompt =~ "Current step: role_transform"
    assert prompt =~ "Allowed actions:"
    assert prompt =~ "- inspire: Use as inspiration"
    assert prompt =~ "- clone: Clone exact skills for editing"
    assert prompt =~ "Selected role profiles: Risk Analyst"
  end

  test "describes table artifacts for review steps" do
    runner =
      FlowRunner.init(CreateFramework, start: :review_taxonomy)
      |> FlowRunner.put_summary(:generate_taxonomy, %{taxonomy_table_name: "taxonomy:Risk"})

    step = FlowRunner.current_node(runner)
    prompt = StepPrompt.build(CreateFramework, runner, step: step, table_name: "taxonomy:Risk")

    assert prompt =~ "Current step: review_taxonomy"
    assert prompt =~ "Table artifact: taxonomy:Risk"
    assert prompt =~ "- generate_skills: Generate skills"
    assert prompt =~ "- regenerate_taxonomy: Regenerate taxonomy"
  end
end
