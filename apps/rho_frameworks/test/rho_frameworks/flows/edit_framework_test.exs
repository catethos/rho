defmodule RhoFrameworks.Flows.EditFrameworkTest do
  use ExUnit.Case, async: false

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
    test "returns 7 nodes: pick → load → review + FinalizeSkeleton tail (which now owns :choose_levels)" do
      steps = EditFramework.steps()
      assert length(steps) == 7

      assert Enum.map(steps, & &1.id) == [
               :pick_existing_library,
               :load_existing_library,
               :review,
               :confirm,
               :choose_levels,
               :proficiency,
               :save
             ]
    end

    test "tail (everything after :review) is byte-identical to FinalizeSkeleton's confirm-onward tail" do
      # FinalizeSkeleton now provides :choose_levels itself between
      # :confirm and :proficiency, so EditFramework no longer needs the
      # custom inject step that used to rewrite :confirm.next. Splicing
      # FinalizeSkeleton's tail (sans :review since EditFramework
      # provides its own) keeps everything in lock-step.
      tail = Enum.drop(EditFramework.steps(), 3)

      assert tail == Enum.drop(FinalizeSkeleton.steps(), 1)
    end

    test ":review advances unconditionally to :confirm (always asks for proficiency scale via :choose_levels)" do
      review = Enum.find(EditFramework.steps(), &(&1.id == :review))

      assert review.type == :table_review
      assert review.routing == :fixed
      # No more conditional fork on :loaded_with_proficiency — even when
      # the library already has proficiency, the user reaches :choose_levels
      # and can keep the default (smart-defaulted to existing modal scale)
      # or change it. The per-skill scale check inside GenerateProficiency
      # is what protects existing rows from accidental regeneration.
      assert review.next == :confirm
    end

    test ":choose_levels is a single-field form with no static default" do
      step = Enum.find(EditFramework.steps(), &(&1.id == :choose_levels))

      assert step.type == :form
      assert step.routing == :fixed
      assert step.next == :proficiency
      assert length(step.config.fields) == 1

      [field] = step.config.fields
      assert field.name == :levels
      assert field.type == :select
      assert field[:required] == true
      # No static default — the form value comes from `populate_intake/3`
      # (smart default = library's modal scale, or 5 if no proficiency yet).
      refute Map.has_key?(field, :default)
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
