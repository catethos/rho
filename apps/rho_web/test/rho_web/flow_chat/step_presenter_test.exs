defmodule RhoWeb.FlowChat.StepPresenterTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.FlowRunner
  alias RhoFrameworks.Flows.CreateFramework
  alias RhoWeb.FlowChat.StepPresenter

  test "renders choose_starting_point as selectable chat actions" do
    runner = FlowRunner.init(CreateFramework)

    message = StepPresenter.present(CreateFramework, runner)

    assert message.kind == :flow_prompt
    assert message.node_id == :choose_starting_point
    assert message.title == "Pick a Starting Point"

    assert Enum.map(message.actions, & &1.id) == [
             "from_template",
             "scratch",
             "extend_existing",
             "merge"
           ]
  end

  test "renders role_transform clone and inspiration actions" do
    runner =
      FlowRunner.init(CreateFramework, start: :role_transform)
      |> FlowRunner.put_summary(:similar_roles, %{
        selected: [%{id: "role-1", name: "Risk Analyst"}]
      })

    message = StepPresenter.present(CreateFramework, runner)

    assert message.node_id == :role_transform

    assert Enum.map(message.actions, & &1.label) == [
             "Use as inspiration",
             "Clone exact skills for editing"
           ]

    clone = Enum.find(message.actions, &(&1.id == "clone"))
    assert clone.payload == %{role_transform: "clone"}
  end

  test "renders taxonomy preference fields with explanatory descriptions" do
    runner = FlowRunner.init(CreateFramework, start: :taxonomy_preferences)

    message = StepPresenter.present(CreateFramework, runner)

    size = Enum.find(message.fields, &(&1.name == :taxonomy_size))
    focus = Enum.find(message.fields, &(&1.name == :transferability))
    levels = Enum.find(message.fields, &(&1.name == :levels))

    assert size.description =~ "how much taxonomy"
    assert size.option_descriptions["compact"] =~ "quick draft"
    assert focus.description =~ "reusable across roles"
    assert levels.option_descriptions["5"] =~ "assessment rubrics"
  end

  test "renders taxonomy review as a table artifact with artifact actions" do
    runner =
      FlowRunner.init(CreateFramework, start: :review_taxonomy)
      |> FlowRunner.put_summary(:generate_taxonomy, %{taxonomy_table_name: "taxonomy:Risk"})

    message = StepPresenter.present(CreateFramework, runner)

    assert message.kind == :flow_artifact
    assert message.artifact == %{kind: :table, table_name: "taxonomy:Risk"}

    assert Enum.map(message.actions, &{&1.id, &1.event}) == [
             {"generate_skills", :continue},
             {"regenerate_taxonomy", :regenerate_step},
             {"focus_table", :focus_table}
           ]

    regenerate = Enum.find(message.actions, &(&1.id == "regenerate_taxonomy"))
    assert regenerate.payload == %{node_id: :generate_taxonomy}
  end

  test "renders cloned skill review as a table artifact with save and reclone actions" do
    runner =
      FlowRunner.init(CreateFramework, start: :review_clone)
      |> FlowRunner.put_summary(:pick_template, %{table_name: "library:Risk"})

    message = StepPresenter.present(CreateFramework, runner, table_name: "library:Risk")

    assert message.kind == :flow_artifact
    assert message.artifact == %{kind: :table, table_name: "library:Risk"}

    assert Enum.map(message.actions, &{&1.id, &1.event}) == [
             {"save_draft", :continue},
             {"reclone_skills", :regenerate_step},
             {"focus_table", :focus_table}
           ]
  end

  test "renders action steps with run action" do
    runner = FlowRunner.init(CreateFramework, start: :pick_template)

    message = StepPresenter.present(CreateFramework, runner, step_status: :idle)

    assert message.node_id == :pick_template
    assert [%{id: "run", event: :run_action}] = message.actions
  end

  test "renders identify gaps completion with gap rationales" do
    runner =
      FlowRunner.init(CreateFramework, start: :identify_gaps)
      |> FlowRunner.put_summary(:identify_gaps, %{
        gaps: [
          %{
            skill_name: "Caching",
            category: "Engineering",
            rationale: "Backend PMs need read-heavy performance patterns."
          },
          %{
            skill_name: "Observability",
            category: "Operations",
            rationale: "The intake calls for production ownership."
          }
        ],
        gap_count: 2
      })

    message = StepPresenter.present(CreateFramework, runner, step_status: :completed)

    assert message.kind == :flow_step_completed
    assert message.body =~ "Identified 2 candidate skills to add"

    assert message.body =~
             "Caching (Engineering) — Backend PMs need read-heavy performance patterns."

    assert message.body =~
             "Observability (Operations) — The intake calls for production ownership."
  end
end
