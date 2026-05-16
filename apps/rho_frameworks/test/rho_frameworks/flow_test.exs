defmodule RhoFrameworks.FlowTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.Flow
  alias RhoFrameworks.Flows.{CreateFramework, Registry}

  describe "CreateFramework behaviour" do
    test "implements Flow callbacks" do
      assert CreateFramework.id() == "create-framework"
      assert CreateFramework.label() == "Create Skill Framework"

      steps = CreateFramework.steps()
      assert is_list(steps)
      assert length(steps) == 27

      ids = Enum.map(steps, & &1.id)

      assert ids == [
               :choose_starting_point,
               :intake_scratch,
               :taxonomy_preferences,
               :intake_template,
               :intake_extend,
               :intake_merge,
               :research,
               :similar_roles,
               :role_transform,
               :pick_template,
               :review_clone,
               :pick_existing_library,
               :load_existing_library,
               :identify_gaps,
               :pick_two_libraries,
               :diff_frameworks,
               :resolve_conflicts,
               :merge_frameworks,
               :generate_taxonomy,
               :review_taxonomy,
               :generate_skills,
               :generate,
               :review,
               :confirm,
               :choose_levels,
               :proficiency,
               :save
             ]
    end

    test "each step has required keys" do
      for step <- CreateFramework.steps() do
        assert is_atom(step.id)
        assert is_binary(step.label)
        assert step.type in [:form, :action, :table_review, :fan_out, :select]
        assert Map.has_key?(step, :config)
        assert Map.has_key?(step, :next)
        assert step.routing in [:fixed, :auto, :agent_loop]
      end
    end

    test "Phase 10a/b/c routing: :choose_starting_point, :similar_roles, :pick_existing_library, :pick_two_libraries use :auto, :research uses :agent_loop, rest :fixed" do
      for step <- CreateFramework.steps() do
        expected =
          case step.id do
            :choose_starting_point -> :auto
            :similar_roles -> :auto
            :pick_existing_library -> :auto
            :pick_two_libraries -> :auto
            :research -> :agent_loop
            _ -> :fixed
          end

        assert step.routing == expected,
               "#{step.id} routing should be #{inspect(expected)}, got #{inspect(step.routing)}"
      end
    end

    test "next: choose_starting_point forks to per-path intake nodes, intake_X advances to its path-specific work step, similar_roles bounces on no matches" do
      steps = CreateFramework.steps()
      next_map = Map.new(steps, fn s -> {s.id, s.next} end)

      assert is_list(next_map[:choose_starting_point])

      from_template_edge =
        Enum.find(next_map[:choose_starting_point], &(&1.guard == :from_template_intent))

      assert from_template_edge.to == :intake_template

      scratch_intent_edge =
        Enum.find(next_map[:choose_starting_point], &(&1.guard == :scratch_intent))

      assert scratch_intent_edge.to == :intake_scratch

      scratch_edge = Enum.find(next_map[:choose_starting_point], &(&1.guard == :scratch))
      assert scratch_edge.to == :intake_scratch

      # Per-path intake nodes funnel into their path-specific work steps.
      assert next_map[:intake_scratch] == :taxonomy_preferences
      assert next_map[:taxonomy_preferences] == :research
      assert next_map[:intake_template] == :similar_roles
      assert next_map[:intake_extend] == :pick_existing_library
      assert next_map[:intake_merge] == :pick_two_libraries

      assert next_map[:research] == :generate_taxonomy
      assert next_map[:generate_taxonomy] == :review_taxonomy
      assert next_map[:review_taxonomy] == :generate_skills
      assert next_map[:generate_skills] == :review
      assert next_map[:generate] == :review
      assert is_list(next_map[:role_transform])

      assert Enum.find(next_map[:role_transform], &(&1.guard == :role_transform_clone)).to ==
               :pick_template

      assert Enum.find(next_map[:role_transform], &(&1.guard == :role_transform_inspire)).to ==
               :taxonomy_preferences

      assert next_map[:pick_template] == :review_clone
      assert next_map[:review_clone] == :save
      assert next_map[:review] == :confirm
      # :confirm now routes to :choose_levels (the new shared form step
      # in FinalizeSkeleton's tail) before proficiency. Always asks the
      # user before any LLM regenerates proficiency on existing skills.
      assert next_map[:confirm] == :choose_levels
      assert next_map[:choose_levels] == :proficiency
      assert next_map[:proficiency] == :save
      assert next_map[:save] == :done

      assert is_list(next_map[:similar_roles])

      good_edge = Enum.find(next_map[:similar_roles], &(&1.guard == :good_matches))
      assert good_edge.to == :role_transform

      bounce_edge = Enum.find(next_map[:similar_roles], &(&1.guard == :no_similar_roles))
      assert bounce_edge.to == :choose_starting_point
    end

    test ":research node references ResearchDomain UseCase" do
      research = Enum.find(CreateFramework.steps(), &(&1.id == :research))
      assert research.type == :action
      assert research.use_case == RhoFrameworks.UseCases.ResearchDomain
      assert research.routing == :agent_loop

      assert research.config[:findings_table] ==
               RhoFrameworks.UseCases.ResearchDomain.table_name()
    end

    test "scratch intake asks identity fields and taxonomy_preferences owns structure fields" do
      steps = CreateFramework.steps()

      scratch = Enum.find(steps, &(&1.id == :intake_scratch))
      assert scratch.type == :form
      assert length(scratch.config.fields) == 4

      scratch_field_names = Enum.map(scratch.config.fields, & &1.name)
      assert :name in scratch_field_names
      assert :description in scratch_field_names
      assert :domain in scratch_field_names
      assert :target_roles in scratch_field_names
      refute :skill_count in scratch_field_names
      refute :levels in scratch_field_names

      prefs = Enum.find(steps, &(&1.id == :taxonomy_preferences))
      pref_field_names = Enum.map(prefs.config.fields, & &1.name)
      assert :taxonomy_size in pref_field_names
      assert :transferability in pref_field_names
      assert :specificity in pref_field_names
      assert :levels in pref_field_names

      for id <- [:intake_template, :intake_extend, :intake_merge] do
        step = Enum.find(steps, &(&1.id == id))
        assert step.type == :form, "#{id} should be :form"
        assert length(step.config.fields) == 2, "#{id} should ask only name + description"

        field_names = Enum.map(step.config.fields, & &1.name)
        assert :name in field_names
        assert :description in field_names

        # Non-scratch paths intentionally omit domain/target_roles/skill_count/levels —
        # those fields are dead-input on those paths today and would mislead users.
        refute :domain in field_names
        refute :target_roles in field_names
        refute :skill_count in field_names
        refute :levels in field_names
      end
    end

    test "choose_starting_point is a form with a single :starting_point select field including extend_existing and merge" do
      step = Enum.find(CreateFramework.steps(), &(&1.id == :choose_starting_point))
      assert step.type == :form
      assert is_list(step.config.fields)
      assert length(step.config.fields) == 1

      [field] = step.config.fields
      assert field.name == :starting_point
      assert field.type == :select
      assert field[:required] == true

      values = Enum.map(field.options, fn {_label, val} -> val end)
      assert "from_template" in values
      assert "scratch" in values
      assert "extend_existing" in values
      assert "merge" in values
    end

    test "Phase 10c merge edges: choose_starting_point→intake_merge→pick_two_libraries→diff→resolve→merge→save" do
      steps = CreateFramework.steps()
      next_map = Map.new(steps, fn s -> {s.id, s.next} end)

      merge_edge =
        Enum.find(next_map[:choose_starting_point], &(&1.guard == :merge_intent))

      assert merge_edge.to == :intake_merge
      assert next_map[:intake_merge] == :pick_two_libraries

      pick_two_edges = next_map[:pick_two_libraries]
      assert is_list(pick_two_edges)

      assert Enum.find(pick_two_edges, &(&1.guard == :two_libraries_picked)).to ==
               :diff_frameworks

      assert Enum.find(pick_two_edges, &(&1.guard == :fewer_than_two_libraries)).to ==
               :choose_starting_point

      assert next_map[:diff_frameworks] == :resolve_conflicts
      assert next_map[:resolve_conflicts] == :merge_frameworks
      assert next_map[:merge_frameworks] == :save
    end

    test "Phase 10c new nodes reference the right UseCases and types" do
      steps = CreateFramework.steps()

      pick_two = Enum.find(steps, &(&1.id == :pick_two_libraries))
      diff = Enum.find(steps, &(&1.id == :diff_frameworks))
      resolve = Enum.find(steps, &(&1.id == :resolve_conflicts))
      merge = Enum.find(steps, &(&1.id == :merge_frameworks))

      assert pick_two.type == :select
      assert pick_two.use_case == RhoFrameworks.UseCases.ListExistingLibraries
      assert pick_two.config.skippable == false
      assert pick_two.config.min_select == 2
      assert pick_two.config.max_select == 2

      assert diff.type == :action
      assert diff.use_case == RhoFrameworks.UseCases.DiffFrameworks

      assert resolve.type == :table_review
      assert resolve.use_case == RhoFrameworks.UseCases.ResolveConflicts
      assert resolve.config.conflict_mode == true

      assert merge.type == :action
      assert merge.use_case == RhoFrameworks.UseCases.MergeFrameworks
    end

    test "Phase 10b extend_existing edges: choose_starting_point→intake_extend→pick_existing_library, bounce on no pick" do
      steps = CreateFramework.steps()
      next_map = Map.new(steps, fn s -> {s.id, s.next} end)

      extend_edge =
        Enum.find(next_map[:choose_starting_point], &(&1.guard == :extend_existing_intent))

      assert extend_edge.to == :intake_extend
      assert next_map[:intake_extend] == :pick_existing_library

      pick_existing_edges = next_map[:pick_existing_library]
      assert is_list(pick_existing_edges)

      ids = Enum.map(pick_existing_edges, & &1.to)
      assert :load_existing_library in ids
      assert :choose_starting_point in ids

      assert Enum.find(pick_existing_edges, &(&1.guard == :existing_library_picked)).to ==
               :load_existing_library

      assert Enum.find(pick_existing_edges, &(&1.guard == :no_existing_libraries)).to ==
               :choose_starting_point

      assert next_map[:load_existing_library] == :identify_gaps
      assert next_map[:identify_gaps] == :generate
    end

    test "Phase 10b new nodes reference the right UseCases" do
      steps = CreateFramework.steps()

      pick_existing = Enum.find(steps, &(&1.id == :pick_existing_library))
      load_existing = Enum.find(steps, &(&1.id == :load_existing_library))
      identify_gaps = Enum.find(steps, &(&1.id == :identify_gaps))

      assert pick_existing.type == :select
      assert pick_existing.use_case == RhoFrameworks.UseCases.ListExistingLibraries
      assert pick_existing.config.skippable == true

      assert load_existing.type == :action
      assert load_existing.use_case == RhoFrameworks.UseCases.LoadExistingFramework

      assert identify_gaps.type == :action
      assert identify_gaps.use_case == RhoFrameworks.UseCases.IdentifyFrameworkGaps
    end

    test "similar_roles step references LoadSimilarRoles use case" do
      step = Enum.find(CreateFramework.steps(), &(&1.id == :similar_roles))
      assert step.type == :select
      assert step.use_case == RhoFrameworks.UseCases.LoadSimilarRoles
      assert step.config.skippable == true
    end

    test "confirm step is manual action" do
      step = Enum.find(CreateFramework.steps(), &(&1.id == :confirm))
      assert step.type == :action
      assert step.config.manual == true
      assert is_binary(step.config.message)
    end

    test "action steps reference UseCases" do
      steps = CreateFramework.steps()
      generate = Enum.find(steps, &(&1.id == :generate))
      save = Enum.find(steps, &(&1.id == :save))
      proficiency = Enum.find(steps, &(&1.id == :proficiency))

      assert generate.use_case == RhoFrameworks.UseCases.GenerateFrameworkSkeletons
      assert save.use_case == RhoFrameworks.UseCases.SaveFramework
      assert proficiency.use_case == RhoFrameworks.UseCases.GenerateProficiency
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
