defmodule RhoFrameworks.Flows.FinalizeSkeletonTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.Flows.FinalizeSkeleton
  alias RhoFrameworks.Scope

  describe "steps/0" do
    test "returns 5 nodes in :review → :confirm → :choose_levels → :proficiency → :save order" do
      steps = FinalizeSkeleton.steps()

      assert length(steps) == 5

      assert Enum.map(steps, & &1.id) == [
               :review,
               :confirm,
               :choose_levels,
               :proficiency,
               :save
             ]
    end

    test "each step has required keys" do
      for step <- FinalizeSkeleton.steps() do
        assert is_atom(step.id)
        assert is_binary(step.label)
        assert step.type in [:form, :action, :table_review, :fan_out, :select]
        assert Map.has_key?(step, :config)
        assert Map.has_key?(step, :next)
        assert step.routing in [:fixed, :auto, :agent_loop]
      end
    end

    test "edge shape: review→confirm→choose_levels→proficiency→save→done" do
      next_map = Map.new(FinalizeSkeleton.steps(), fn s -> {s.id, s.next} end)

      assert next_map[:review] == :confirm
      assert next_map[:confirm] == :choose_levels
      assert next_map[:choose_levels] == :proficiency
      assert next_map[:proficiency] == :save
      assert next_map[:save] == :done
    end

    test ":confirm carries manual config and message" do
      confirm = Enum.find(FinalizeSkeleton.steps(), &(&1.id == :confirm))

      assert confirm.type == :action
      assert confirm.config.manual == true
      assert is_binary(confirm.config.message)
    end

    test ":proficiency is fan_out and references GenerateProficiency" do
      step = Enum.find(FinalizeSkeleton.steps(), &(&1.id == :proficiency))

      assert step.type == :fan_out
      assert step.use_case == RhoFrameworks.UseCases.GenerateProficiency
    end

    test ":save references SaveFramework" do
      step = Enum.find(FinalizeSkeleton.steps(), &(&1.id == :save))

      assert step.type == :action
      assert step.use_case == RhoFrameworks.UseCases.SaveFramework
    end

    test ":review and :generate seam — first node is :review (parent's :generate splices in before)" do
      assert hd(FinalizeSkeleton.steps()).id == :review
    end
  end

  describe "build_input/3" do
    setup do
      %{scope: %Scope{organization_id: "org_test", session_id: nil}}
    end

    test ":review and :confirm return empty maps", %{scope: scope} do
      assert FinalizeSkeleton.build_input(:review, %{intake: %{}, summaries: %{}}, scope) ==
               %{}

      assert FinalizeSkeleton.build_input(:confirm, %{intake: %{}, summaries: %{}}, scope) ==
               %{}
    end

    test ":proficiency reads table_name from :generate summary, levels from intake verbatim", %{
      scope: scope
    } do
      # `levels` now passes through unchanged — string in, string out.
      # The downstream UseCase (`GenerateProficiency.run`) parses it to
      # int. Coercing nil → 5 here would mask the "user never picked"
      # signal the UseCase relies on for its early-exit safety net.
      state = %{
        intake: %{name: "Backend", levels: "5"},
        summaries: %{generate: %{table_name: "backend_skills"}}
      }

      assert FinalizeSkeleton.build_input(:proficiency, state, scope) == %{
               table_name: "backend_skills",
               levels: "5"
             }
    end

    test ":proficiency falls back to derived table name when generate summary missing", %{
      scope: scope
    } do
      state = %{intake: %{name: "Backend", levels: 3}, summaries: %{}}

      result = FinalizeSkeleton.build_input(:proficiency, state, scope)

      assert is_binary(result.table_name)
      assert result.table_name != ""
      # Integer levels still pass through verbatim — the UseCase handles
      # int and string forms.
      assert result.levels == 3
    end

    test ":proficiency tolerates string keys in intake", %{scope: scope} do
      state = %{
        intake: %{"name" => "Backend", "levels" => "4"},
        summaries: %{generate: %{table_name: "tn"}}
      }

      assert FinalizeSkeleton.build_input(:proficiency, state, scope) == %{
               table_name: "tn",
               levels: "4"
             }
    end

    test ":proficiency passes nil through when intake has no levels (early-exit signal)", %{
      scope: scope
    } do
      # The :choose_levels step in the shared tail makes this state
      # unreachable from the wizard, but the no-coerce shape preserves
      # the early-exit signal for any caller that bypasses the wizard.
      state = %{intake: %{name: "Backend"}, summaries: %{generate: %{table_name: "tn"}}}

      assert FinalizeSkeleton.build_input(:proficiency, state, scope) == %{
               table_name: "tn",
               levels: nil
             }
    end

    test ":save prefers merge → template → generate → load_existing for table_name", %{
      scope: scope
    } do
      state = %{
        intake: %{name: "X"},
        summaries: %{
          merge_frameworks: %{table_name: "merge_t", library_id: "merge_lib"},
          pick_template: %{table_name: "tpl_t", library_id: "tpl_lib"},
          generate: %{table_name: "gen_t", library_id: "gen_lib"},
          load_existing_library: %{table_name: "load_t"}
        }
      }

      assert FinalizeSkeleton.build_input(:save, state, scope) == %{
               table_name: "merge_t",
               library_id: "merge_lib"
             }
    end

    test ":save falls through to generate when merge/template missing", %{scope: scope} do
      state = %{
        intake: %{name: "X"},
        summaries: %{generate: %{table_name: "gen_t", library_id: "gen_lib"}}
      }

      assert FinalizeSkeleton.build_input(:save, state, scope) == %{
               table_name: "gen_t",
               library_id: "gen_lib"
             }
    end
  end
end
