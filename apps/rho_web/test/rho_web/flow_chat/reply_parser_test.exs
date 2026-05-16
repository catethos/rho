defmodule RhoWeb.FlowChat.ReplyParserTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.FlowRunner
  alias RhoFrameworks.Flows.CreateFramework
  alias RhoWeb.FlowChat.{ReplyParser, StepPresenter}

  test "button payload wins by action id" do
    message =
      CreateFramework
      |> FlowRunner.init(start: :role_transform)
      |> then(&StepPresenter.present(CreateFramework, &1))

    assert {:ok, %{action_id: "clone", payload: %{role_transform: "clone"}, event: :submit_form}} =
             ReplyParser.parse_action(message, "clone")
  end

  test "maps natural-language clone replies for role_transform" do
    message =
      CreateFramework
      |> FlowRunner.init(start: :role_transform)
      |> then(&StepPresenter.present(CreateFramework, &1))

    assert {:ok, %{action_id: "clone", payload: %{role_transform: "clone"}}} =
             ReplyParser.parse_reply(message, "clone them, I only want surgical edits")
  end

  test "maps natural-language inspiration replies for role_transform" do
    message =
      CreateFramework
      |> FlowRunner.init(start: :role_transform)
      |> then(&StepPresenter.present(CreateFramework, &1))

    assert {:ok, %{action_id: "inspire", payload: %{role_transform: "inspire"}}} =
             ReplyParser.parse_reply(message, "use them as inspiration")
  end

  test "maps balanced reply for taxonomy preferences" do
    message =
      CreateFramework
      |> FlowRunner.init(start: :taxonomy_preferences)
      |> then(&StepPresenter.present(CreateFramework, &1))

    assert {:ok, %{event: :submit_form, payload: payload}} =
             ReplyParser.parse_reply(message, "balanced")

    assert payload[:taxonomy_size] == "balanced"
    assert payload[:levels] == "5"
  end

  test "maps continue on review_taxonomy" do
    runner =
      FlowRunner.init(CreateFramework, start: :review_taxonomy)
      |> FlowRunner.put_summary(:generate_taxonomy, %{taxonomy_table_name: "taxonomy:Risk"})

    message = StepPresenter.present(CreateFramework, runner)

    assert {:ok, %{action_id: "generate_skills", event: :continue}} =
             ReplyParser.parse_reply(message, "looks good, continue")
  end

  test "maps regenerate taxonomy replies on review_taxonomy" do
    runner =
      FlowRunner.init(CreateFramework, start: :review_taxonomy)
      |> FlowRunner.put_summary(:generate_taxonomy, %{taxonomy_table_name: "taxonomy:Risk"})

    message = StepPresenter.present(CreateFramework, runner)

    assert {:ok,
            %{
              action_id: "regenerate_taxonomy",
              event: :regenerate_step,
              payload: %{node_id: :generate_taxonomy}
            }} = ReplyParser.parse_reply(message, "regenerate taxonomy")
  end
end
