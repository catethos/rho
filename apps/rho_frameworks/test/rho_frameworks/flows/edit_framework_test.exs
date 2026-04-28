defmodule RhoFrameworks.Flows.EditFrameworkTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.Flows.{EditFramework, FinalizeSkeleton, Registry}
  alias RhoFrameworks.Scope

  describe "Flow callbacks" do
    test "id, label" do
      assert EditFramework.id() == "edit-framework"
      assert EditFramework.label() == "Edit Skill Framework"
    end

    test "registered in Flows.Registry" do
      assert {:ok, EditFramework} = Registry.get("edit-framework")
      assert "edit-framework" in Registry.list()
    end
  end

  describe "steps/0" do
    test "returns 6 nodes: pick → load + 4-node FinalizeSkeleton tail" do
      steps = EditFramework.steps()
      assert length(steps) == 6

      assert Enum.map(steps, & &1.id) == [
               :pick_existing_library,
               :load_existing_library,
               :review,
               :confirm,
               :proficiency,
               :save
             ]
    end

    test ":confirm/:proficiency/:save tail is byte-identical to FinalizeSkeleton's tail" do
      # EditFramework overrides FinalizeSkeleton's :review (multi-edge
      # next that skips :confirm+:proficiency when the loaded library
      # already has proficiency levels). The remaining 3-step tail
      # (:confirm → :proficiency → :save) must remain spliced verbatim.
      tail =
        EditFramework.steps()
        |> Enum.drop(3)

      assert tail == Enum.drop(FinalizeSkeleton.steps(), 1)
    end

    test ":review forks on proficiency presence" do
      review = Enum.find(EditFramework.steps(), &(&1.id == :review))

      assert review.type == :table_review
      assert review.routing == :auto

      save_edge = Enum.find(review.next, &(&1.guard == :loaded_with_proficiency))
      assert save_edge.to == :save

      confirm_edge = Enum.find(review.next, &(&1.guard == :loaded_without_proficiency))
      assert confirm_edge.to == :confirm
    end

    test "each step has required keys" do
      for step <- EditFramework.steps() do
        assert is_atom(step.id)
        assert is_binary(step.label)
        assert step.type in [:form, :action, :table_review, :fan_out, :select]
        assert Map.has_key?(step, :config)
        assert Map.has_key?(step, :next)
        assert step.routing in [:fixed, :auto, :agent_loop]
      end
    end

    test ":pick_existing_library has guarded edges to load + self-loop on no libraries" do
      pick = Enum.find(EditFramework.steps(), &(&1.id == :pick_existing_library))

      assert pick.type == :select
      assert pick.use_case == RhoFrameworks.UseCases.ListExistingLibraries
      assert pick.routing == :auto

      picked_edge = Enum.find(pick.next, &(&1.guard == :existing_library_picked))
      assert picked_edge.to == :load_existing_library

      none_edge = Enum.find(pick.next, &(&1.guard == :no_existing_libraries))
      assert none_edge.to == :pick_existing_library
    end

    test ":load_existing_library advances to :review (FinalizeSkeleton head)" do
      step = Enum.find(EditFramework.steps(), &(&1.id == :load_existing_library))

      assert step.type == :action
      assert step.use_case == RhoFrameworks.UseCases.LoadExistingFramework
      assert step.next == :review
      assert step.routing == :fixed
    end

    test ":save still advances to :done via FinalizeSkeleton" do
      next_map = Map.new(EditFramework.steps(), fn s -> {s.id, s.next} end)
      assert next_map[:save] == :done
    end
  end

  describe "build_input/3" do
    setup do
      %{scope: %Scope{organization_id: "org_test", session_id: nil}}
    end

    test ":pick_existing_library returns empty map", %{scope: scope} do
      assert EditFramework.build_input(
               :pick_existing_library,
               %{intake: %{}, summaries: %{}},
               scope
             ) ==
               %{}
    end

    test ":load_existing_library extracts library_id from picker summary", %{scope: scope} do
      state = %{
        intake: %{},
        summaries: %{
          pick_existing_library: %{
            matches: [%{id: "lib-1", name: "Backend"}],
            selected: [%{id: "lib-1", name: "Backend"}],
            skip_reason: nil
          }
        }
      }

      assert EditFramework.build_input(:load_existing_library, state, scope) == %{
               library_id: "lib-1"
             }
    end

    test ":load_existing_library returns nil library_id when nothing picked", %{scope: scope} do
      state = %{
        intake: %{},
        summaries: %{pick_existing_library: %{matches: [], selected: [], skip_reason: nil}}
      }

      assert EditFramework.build_input(:load_existing_library, state, scope) == %{
               library_id: nil
             }
    end

    test ":review and :confirm delegate to FinalizeSkeleton (empty maps)", %{scope: scope} do
      state = %{intake: %{}, summaries: %{}}

      assert EditFramework.build_input(:review, state, scope) == %{}
      assert EditFramework.build_input(:confirm, state, scope) == %{}
    end

    test ":proficiency delegates to FinalizeSkeleton (reads intake.levels, table_name)",
         %{scope: scope} do
      state = %{
        intake: %{name: "Backend", levels: "4"},
        summaries: %{generate: %{table_name: "tn"}}
      }

      assert EditFramework.build_input(:proficiency, state, scope) ==
               FinalizeSkeleton.build_input(:proficiency, state, scope)
    end

    test ":save pins library_id and table_name to load_existing_library summary (NOT intake.name)",
         %{scope: scope} do
      # The whole point of edit_framework is writing back to the SAME
      # library row. FinalizeSkeleton's :save chain falls through to
      # lookup-by-intake-name which would create a new row when intake
      # has no name (the edit flow doesn't go through :intake).
      state = %{
        intake: %{},
        summaries: %{
          load_existing_library: %{
            library_id: "edited-lib-123",
            library_name: "SFIA",
            table_name: "library:SFIA",
            skill_count: 50,
            role_count: 0
          }
        }
      }

      assert EditFramework.build_input(:save, state, scope) == %{
               library_id: "edited-lib-123",
               table_name: "library:SFIA"
             }
    end

    test ":save ignores generate/template/merge summaries even when present", %{scope: scope} do
      # Defensive: FinalizeSkeleton's chain prefers merge → template →
      # generate. EditFramework overrides that — only load_existing wins.
      state = %{
        intake: %{name: "wrong-name"},
        summaries: %{
          load_existing_library: %{library_id: "load-id", table_name: "load-tn"},
          generate: %{library_id: "gen-id", table_name: "gen-tn"},
          merge_frameworks: %{library_id: "merge-id", table_name: "merge-tn"}
        }
      }

      assert EditFramework.build_input(:save, state, scope) == %{
               library_id: "load-id",
               table_name: "load-tn"
             }
    end
  end
end
