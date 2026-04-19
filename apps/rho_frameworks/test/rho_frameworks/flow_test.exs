defmodule RhoFrameworks.FlowTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.Flow
  alias RhoFrameworks.Flows.{CreateFramework, Registry}

  describe "CreateFramework behaviour" do
    test "implements Flow callbacks" do
      assert CreateFramework.id() == "create-framework"
      assert CreateFramework.label() == "Create Skill Framework"

      steps = CreateFramework.steps()
      assert is_list(steps)
      assert length(steps) == 7

      ids = Enum.map(steps, & &1.id)
      assert ids == [:intake, :similar_roles, :generate, :review, :confirm, :proficiency, :save]
    end

    test "each step has required keys" do
      for step <- CreateFramework.steps() do
        assert is_atom(step.id)
        assert is_binary(step.label)
        assert step.type in [:form, :action, :table_review, :fan_out, :select]
        assert Map.has_key?(step, :run)
        assert Map.has_key?(step, :config)
      end
    end

    test "intake step has form fields" do
      intake = Enum.find(CreateFramework.steps(), &(&1.id == :intake))
      assert intake.type == :form
      assert is_list(intake.config.fields)
      assert length(intake.config.fields) == 6

      field_names = Enum.map(intake.config.fields, & &1.name)
      assert :name in field_names
      assert :description in field_names
      assert :domain in field_names
      assert :target_roles in field_names
      assert :skill_count in field_names
      assert :levels in field_names
    end

    test "similar_roles step has load config" do
      step = Enum.find(CreateFramework.steps(), &(&1.id == :similar_roles))
      assert step.type == :select
      assert {CreateFramework, :load_similar_roles, []} = step.config.load
      assert step.config.skippable == true
    end

    test "confirm step is manual action" do
      step = Enum.find(CreateFramework.steps(), &(&1.id == :confirm))
      assert step.type == :action
      assert step.config.manual == true
      assert is_binary(step.config.message)
    end

    test "action steps have run tuples" do
      steps = CreateFramework.steps()
      generate = Enum.find(steps, &(&1.id == :generate))
      save = Enum.find(steps, &(&1.id == :save))

      assert {RhoFrameworks.SkeletonGenerator, :generate, []} = generate.run
      assert {RhoFrameworks.Library.Editor, :save_table, []} = save.run
    end
  end

  describe "Registry" do
    test "get/1 returns module for known flow" do
      assert {:ok, CreateFramework} = Registry.get("create-framework")
    end

    test "get/1 returns :error for unknown flow" do
      assert :error = Registry.get("unknown-flow")
    end

    test "list/0 returns all flow IDs" do
      ids = Registry.list()
      assert "create-framework" in ids
    end
  end

  describe "Flow behaviour type enforcement" do
    test "CreateFramework exports behaviour callbacks" do
      callbacks = Flow.behaviour_info(:callbacks)
      assert {:id, 0} in callbacks
      assert {:label, 0} in callbacks
      assert {:steps, 0} in callbacks
    end
  end
end
