defmodule RhoFrameworks.FlowRunnerTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.{FlowRunner, Scope}
  alias RhoFrameworks.Flow.Policies.Deterministic

  # ──────────────────────────────────────────────────────────────────────
  # Test fixtures
  # ──────────────────────────────────────────────────────────────────────

  defmodule SyncUseCase do
    @behaviour RhoFrameworks.UseCase

    @impl true
    def describe do
      %{id: :sync_uc, label: "Sync test", cost_hint: :instant}
    end

    @impl true
    def run(input, %Scope{}), do: {:ok, %{echo: input, summary: "ran"}}
  end

  defmodule AsyncUseCase do
    @behaviour RhoFrameworks.UseCase

    @impl true
    def describe do
      %{id: :async_uc, label: "Async test", cost_hint: :agent}
    end

    @impl true
    def run(_input, %Scope{}), do: {:async, %{agent_id: "agent-fixture-1"}}
  end

  defmodule FixtureFlow do
    @behaviour RhoFrameworks.Flow

    @impl true
    def id, do: "fixture-flow"

    @impl true
    def label, do: "Fixture Flow"

    @impl true
    def steps do
      [
        %{
          id: :intake,
          label: "Intake",
          type: :form,
          next: :work,
          routing: :fixed,
          config: %{}
        },
        %{
          id: :work,
          label: "Work",
          type: :action,
          use_case: SyncUseCase,
          next: :async_work,
          routing: :fixed,
          config: %{}
        },
        %{
          id: :async_work,
          label: "Async Work",
          type: :action,
          use_case: AsyncUseCase,
          next: :review,
          routing: :fixed,
          config: %{}
        },
        %{
          id: :review,
          label: "Review",
          type: :table_review,
          next: :done,
          routing: :fixed,
          config: %{}
        }
      ]
    end

    @impl true
    def build_input(:work, %{intake: intake}, %Scope{}) do
      %{name: Map.get(intake, :name, "default")}
    end

    def build_input(_, _, _), do: %{}
  end

  # Branching fixture for the Deterministic guard path.
  defmodule BranchFlow do
    @behaviour RhoFrameworks.Flow

    @impl true
    def id, do: "branch-flow"

    @impl true
    def label, do: "Branch Flow"

    @impl true
    def steps do
      [
        %{
          id: :start,
          label: "Start",
          type: :action,
          next: [
            %{to: :left, guard: nil, label: "left (default)"},
            %{to: :right, guard: nil, label: "right"}
          ],
          routing: :fixed,
          config: %{}
        },
        %{id: :left, label: "Left", type: :action, next: :done, routing: :fixed, config: %{}},
        %{id: :right, label: "Right", type: :action, next: :done, routing: :fixed, config: %{}}
      ]
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Tests
  # ──────────────────────────────────────────────────────────────────────

  setup do
    scope = %Scope{organization_id: "org-test", session_id: "sess-test"}
    {:ok, scope: scope}
  end

  describe "init/2" do
    test "starts at the first step by default" do
      state = FlowRunner.init(FixtureFlow)
      assert state.flow_mod == FixtureFlow
      assert state.node_id == :intake
      assert state.intake == %{}
      assert state.summaries == %{}
    end

    test "respects :start, :intake, :summaries opts" do
      state =
        FlowRunner.init(FixtureFlow,
          start: :work,
          intake: %{name: "x"},
          summaries: %{intake: %{ok: true}}
        )

      assert state.node_id == :work
      assert state.intake == %{name: "x"}
      assert state.summaries == %{intake: %{ok: true}}
    end
  end

  describe "current_node/1" do
    test "returns the step_def for the current node_id" do
      state = FlowRunner.init(FixtureFlow, start: :work)
      assert %{id: :work, type: :action} = FlowRunner.current_node(state)
    end

    test "returns nil at :done" do
      state = FlowRunner.init(FixtureFlow) |> FlowRunner.advance(:done)
      assert FlowRunner.current_node(state) == nil
      assert FlowRunner.done?(state)
    end
  end

  describe "intake / summaries mutators" do
    test "put_intake replaces the intake map" do
      state = FlowRunner.init(FixtureFlow) |> FlowRunner.put_intake(%{a: 1})
      assert state.intake == %{a: 1}
    end

    test "merge_intake merges keys" do
      state =
        FlowRunner.init(FixtureFlow)
        |> FlowRunner.put_intake(%{a: 1})
        |> FlowRunner.merge_intake(%{b: 2})

      assert state.intake == %{a: 1, b: 2}
    end

    test "put_summary stores per-node summaries" do
      state =
        FlowRunner.init(FixtureFlow)
        |> FlowRunner.put_summary(:work, %{result: :ok})

      assert state.summaries == %{work: %{result: :ok}}
    end
  end

  describe "build_input/3" do
    test "delegates to flow_mod.build_input/3 when defined", %{scope: scope} do
      state = FlowRunner.init(FixtureFlow, intake: %{name: "Alice"})
      node = FlowRunner.current_node(%{state | node_id: :work})
      assert FlowRunner.build_input(node, state, scope) == %{name: "Alice"}
    end

    test "returns %{} when flow_mod doesn't define a build_input clause", %{scope: scope} do
      state = FlowRunner.init(FixtureFlow, start: :review)
      node = FlowRunner.current_node(state)
      assert FlowRunner.build_input(node, state, scope) == %{}
    end
  end

  describe "run_node/3" do
    test "dispatches to the node's use_case with built input", %{scope: scope} do
      state = FlowRunner.init(FixtureFlow, start: :work, intake: %{name: "Bob"})
      node = FlowRunner.current_node(state)

      assert {:ok, %{echo: %{name: "Bob"}, summary: "ran"}} =
               FlowRunner.run_node(node, state, scope)
    end

    test "returns {:async, ...} for async UseCases", %{scope: scope} do
      state = FlowRunner.init(FixtureFlow, start: :async_work)
      node = FlowRunner.current_node(state)

      assert {:async, %{agent_id: "agent-fixture-1"}} =
               FlowRunner.run_node(node, state, scope)
    end

    test "returns {:error, :no_use_case} for nodes with no use_case", %{scope: scope} do
      state = FlowRunner.init(FixtureFlow, start: :intake)
      node = FlowRunner.current_node(state)
      assert {:error, :no_use_case} = FlowRunner.run_node(node, state, scope)
    end
  end

  describe "choose_next/5 — Deterministic policy" do
    test "follows next: through single-edge nodes" do
      state = FlowRunner.init(FixtureFlow, start: :work)
      node = FlowRunner.current_node(state)

      assert {:ok, :async_work, %{reason: nil, confidence: nil}} =
               FlowRunner.choose_next(FixtureFlow, node, state, Deterministic)
    end

    test "returns :done when node.next is :done" do
      state = FlowRunner.init(FixtureFlow, start: :review)
      node = FlowRunner.current_node(state)

      assert {:ok, :done, %{reason: nil, confidence: nil}} =
               FlowRunner.choose_next(FixtureFlow, node, state, Deterministic)
    end

    test "picks the first edge on a list-of-edges node (no guards)" do
      state = FlowRunner.init(BranchFlow)
      node = FlowRunner.current_node(state)

      assert {:ok, :left, %{reason: nil, confidence: nil}} =
               FlowRunner.choose_next(BranchFlow, node, state, Deterministic)
    end

    test "ignores :routing — :auto and :agent_loop are picked the same way" do
      # Hand-build a fake current_node with :routing :auto. Deterministic
      # must not branch on it; it just picks first edge.
      node = %{
        id: :x,
        label: "X",
        type: :action,
        next: [%{to: :a, guard: nil, label: "first"}, %{to: :b, guard: nil, label: "second"}],
        routing: :auto,
        config: %{}
      }

      state = %{flow_mod: BranchFlow, node_id: :x, intake: %{}, summaries: %{}}

      assert {:ok, :a, _} =
               FlowRunner.choose_next(BranchFlow, node, state, Deterministic)
    end
  end

  describe "guard?/2" do
    test "raises on unknown guard names" do
      assert_raise ArgumentError, ~r/unknown FlowRunner guard/, fn ->
        FlowRunner.guard?(:no_such_guard, %{summaries: %{}})
      end
    end

    test ":good_matches is true only when matches and selected are both non-empty" do
      good = %{
        summaries: %{
          similar_roles: %{
            matches: [%{name: "Backend"}],
            selected: [%{name: "Backend"}],
            skip_reason: nil
          }
        }
      }

      assert FlowRunner.guard?(:good_matches, good)
      refute FlowRunner.guard?(:no_matches, good)
    end

    test ":no_matches is true when summary is missing" do
      empty = %{summaries: %{}}
      refute FlowRunner.guard?(:good_matches, empty)
      assert FlowRunner.guard?(:no_matches, empty)
    end

    test ":no_matches is true when matches is empty" do
      none = %{
        summaries: %{
          similar_roles: %{matches: [], selected: [], skip_reason: "user skipped"}
        }
      }

      refute FlowRunner.guard?(:good_matches, none)
      assert FlowRunner.guard?(:no_matches, none)
    end

    test ":no_matches is true when matches is non-empty but selected is empty" do
      not_picked = %{
        summaries: %{
          similar_roles: %{
            matches: [%{name: "Backend"}],
            selected: [],
            skip_reason: "user skipped"
          }
        }
      }

      refute FlowRunner.guard?(:good_matches, not_picked)
      assert FlowRunner.guard?(:no_matches, not_picked)
    end

    test ":no_similar_roles mirrors :no_matches semantics" do
      good = %{
        summaries: %{
          similar_roles: %{
            matches: [%{name: "Backend"}],
            selected: [%{name: "Backend"}],
            skip_reason: nil
          }
        }
      }

      refute FlowRunner.guard?(:no_similar_roles, good)

      empty = %{summaries: %{}}
      assert FlowRunner.guard?(:no_similar_roles, empty)

      no_matches = %{
        summaries: %{
          similar_roles: %{matches: [], selected: [], skip_reason: nil}
        }
      }

      assert FlowRunner.guard?(:no_similar_roles, no_matches)

      not_picked = %{
        summaries: %{
          similar_roles: %{
            matches: [%{name: "Backend"}],
            selected: [],
            skip_reason: "user skipped"
          }
        }
      }

      assert FlowRunner.guard?(:no_similar_roles, not_picked)
    end

    test ":from_template_intent reads intake[:starting_point] as a string" do
      assert FlowRunner.guard?(:from_template_intent, %{
               intake: %{starting_point: "from_template"}
             })

      assert FlowRunner.guard?(:from_template_intent, %{
               intake: %{"starting_point" => "from_template"}
             })

      refute FlowRunner.guard?(:from_template_intent, %{
               intake: %{starting_point: "scratch"}
             })

      refute FlowRunner.guard?(:from_template_intent, %{intake: %{}})
      refute FlowRunner.guard?(:from_template_intent, %{summaries: %{}})
    end

    test ":scratch_intent reads intake[:starting_point] as a string" do
      assert FlowRunner.guard?(:scratch_intent, %{
               intake: %{starting_point: "scratch"}
             })

      assert FlowRunner.guard?(:scratch_intent, %{
               intake: %{"starting_point" => "scratch"}
             })

      refute FlowRunner.guard?(:scratch_intent, %{
               intake: %{starting_point: "from_template"}
             })

      refute FlowRunner.guard?(:scratch_intent, %{intake: %{}})
      refute FlowRunner.guard?(:scratch_intent, %{summaries: %{}})
    end

    test ":scratch_intent fires regardless of populated domain/target_roles" do
      # Distinguishes :scratch_intent (explicit form choice) from :scratch
      # (implicit blank-intake heuristic).
      assert FlowRunner.guard?(:scratch_intent, %{
               intake: %{
                 starting_point: "scratch",
                 domain: "Software Engineering",
                 target_roles: "Backend"
               }
             })
    end

    test ":extend_existing_intent reads intake[:starting_point] as a string" do
      assert FlowRunner.guard?(:extend_existing_intent, %{
               intake: %{starting_point: "extend_existing"}
             })

      assert FlowRunner.guard?(:extend_existing_intent, %{
               intake: %{"starting_point" => "extend_existing"}
             })

      refute FlowRunner.guard?(:extend_existing_intent, %{
               intake: %{starting_point: "scratch"}
             })

      refute FlowRunner.guard?(:extend_existing_intent, %{intake: %{}})
    end

    test ":existing_library_picked is true only when pick_existing_library has a non-empty selected" do
      picked = %{
        summaries: %{
          pick_existing_library: %{
            matches: [%{id: "lib-1", name: "Eng"}],
            selected: [%{id: "lib-1", name: "Eng"}],
            skip_reason: nil
          }
        }
      }

      assert FlowRunner.guard?(:existing_library_picked, picked)
      refute FlowRunner.guard?(:no_existing_libraries, picked)
    end

    test ":no_existing_libraries fires when summary missing, empty selected, or org has none" do
      assert FlowRunner.guard?(:no_existing_libraries, %{summaries: %{}})

      not_picked = %{
        summaries: %{
          pick_existing_library: %{
            matches: [%{id: "lib-1"}],
            selected: [],
            skip_reason: "user skipped"
          }
        }
      }

      assert FlowRunner.guard?(:no_existing_libraries, not_picked)
      refute FlowRunner.guard?(:existing_library_picked, not_picked)

      empty_org = %{
        summaries: %{
          pick_existing_library: %{matches: [], selected: [], skip_reason: "no frameworks"}
        }
      }

      assert FlowRunner.guard?(:no_existing_libraries, empty_org)
    end

    test ":loaded_with_proficiency reads has_proficiency from load_existing_library summary" do
      with_prof = %{
        summaries: %{
          load_existing_library: %{
            library_id: "lib-1",
            table_name: "library:Backend",
            skill_count: 5,
            has_proficiency: true
          }
        }
      }

      assert FlowRunner.guard?(:loaded_with_proficiency, with_prof)
      refute FlowRunner.guard?(:loaded_without_proficiency, with_prof)
    end

    test ":loaded_without_proficiency fires when has_proficiency is false or summary missing" do
      assert FlowRunner.guard?(:loaded_without_proficiency, %{summaries: %{}})

      without_prof = %{
        summaries: %{
          load_existing_library: %{
            library_id: "lib-1",
            table_name: "library:Backend",
            skill_count: 5,
            has_proficiency: false
          }
        }
      }

      assert FlowRunner.guard?(:loaded_without_proficiency, without_prof)
      refute FlowRunner.guard?(:loaded_with_proficiency, without_prof)
    end

    test ":merge_intent reads intake[:starting_point] as a string" do
      assert FlowRunner.guard?(:merge_intent, %{intake: %{starting_point: "merge"}})
      assert FlowRunner.guard?(:merge_intent, %{intake: %{"starting_point" => "merge"}})
      refute FlowRunner.guard?(:merge_intent, %{intake: %{starting_point: "scratch"}})
      refute FlowRunner.guard?(:merge_intent, %{intake: %{}})
      refute FlowRunner.guard?(:merge_intent, %{summaries: %{}})
    end

    test ":two_libraries_picked is true only when exactly two libraries are selected" do
      two = %{
        summaries: %{
          pick_two_libraries: %{
            matches: [%{id: "a"}, %{id: "b"}, %{id: "c"}],
            selected: [%{id: "a"}, %{id: "b"}]
          }
        }
      }

      assert FlowRunner.guard?(:two_libraries_picked, two)
      refute FlowRunner.guard?(:fewer_than_two_libraries, two)
    end

    test ":fewer_than_two_libraries fires when summary missing or selection too small" do
      assert FlowRunner.guard?(:fewer_than_two_libraries, %{summaries: %{}})

      one = %{
        summaries: %{
          pick_two_libraries: %{matches: [%{id: "a"}], selected: [%{id: "a"}]}
        }
      }

      assert FlowRunner.guard?(:fewer_than_two_libraries, one)
      refute FlowRunner.guard?(:two_libraries_picked, one)

      none = %{
        summaries: %{pick_two_libraries: %{matches: [], selected: []}}
      }

      assert FlowRunner.guard?(:fewer_than_two_libraries, none)
    end

    test ":fewer_than_two_libraries fires when more than two are picked" do
      three = %{
        summaries: %{
          pick_two_libraries: %{
            matches: [%{id: "a"}, %{id: "b"}, %{id: "c"}],
            selected: [%{id: "a"}, %{id: "b"}, %{id: "c"}]
          }
        }
      }

      refute FlowRunner.guard?(:two_libraries_picked, three)
      assert FlowRunner.guard?(:fewer_than_two_libraries, three)
    end
  end

  describe "advance/2 + done?/1 — full state machine drive" do
    test "drives the fixture flow end-to-end through summaries and advances", %{scope: scope} do
      state =
        FlowRunner.init(FixtureFlow)
        |> FlowRunner.put_intake(%{name: "Eve"})

      # Move past intake (no UseCase) — manual advance
      {:ok, next_id, _} =
        FlowRunner.choose_next(
          FixtureFlow,
          FlowRunner.current_node(state),
          state,
          Deterministic
        )

      state = FlowRunner.advance(state, next_id)
      assert state.node_id == :work

      # Run :work synchronously, store summary, advance
      {:ok, summary} = FlowRunner.run_node(FlowRunner.current_node(state), state, scope)
      state = FlowRunner.put_summary(state, :work, summary)

      {:ok, next_id, _} =
        FlowRunner.choose_next(
          FixtureFlow,
          FlowRunner.current_node(state),
          state,
          Deterministic
        )

      state = FlowRunner.advance(state, next_id)
      assert state.node_id == :async_work

      # Run :async_work — caller would track agent_id externally; just record summary
      {:async, async_sum} = FlowRunner.run_node(FlowRunner.current_node(state), state, scope)
      state = FlowRunner.put_summary(state, :async_work, async_sum)

      {:ok, next_id, _} =
        FlowRunner.choose_next(
          FixtureFlow,
          FlowRunner.current_node(state),
          state,
          Deterministic
        )

      state = FlowRunner.advance(state, next_id)
      assert state.node_id == :review

      {:ok, :done, _} =
        FlowRunner.choose_next(
          FixtureFlow,
          FlowRunner.current_node(state),
          state,
          Deterministic
        )

      state = FlowRunner.advance(state, :done)
      assert FlowRunner.done?(state)

      assert state.summaries == %{
               work: %{echo: %{name: "Eve"}, summary: "ran"},
               async_work: %{agent_id: "agent-fixture-1"}
             }
    end
  end

  describe "CreateFramework integration" do
    alias RhoFrameworks.Flows.CreateFramework

    test "every step has a use_case or is a UI-only node" do
      # :table_review nodes are UI-only **unless** they declare
      # `conflict_mode: true`, in which case they wire a UseCase whose
      # `run/2` validates the user's per-row picks before the LV
      # advances (Phase 10c — :resolve_conflicts).
      ui_only_types = [:form]

      for step <- CreateFramework.steps() do
        cond do
          step.type in ui_only_types ->
            refute Map.has_key?(step, :use_case)

          step.type == :table_review and step.config[:conflict_mode] != true ->
            refute Map.has_key?(step, :use_case)

          step.id == :confirm ->
            # manual action — no use_case
            refute Map.has_key?(step, :use_case)

          true ->
            assert is_atom(step.use_case)
            Code.ensure_loaded(step.use_case)
            assert function_exported?(step.use_case, :run, 2)
            assert function_exported?(step.use_case, :describe, 0)
        end
      end
    end

    test "build_input shape matches the wired UseCases", %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework,
          intake: %{name: "Eng", description: "d", domain: "SE"}
        )

      similar_node = Enum.find(CreateFramework.steps(), &(&1.id == :similar_roles))
      input = FlowRunner.build_input(similar_node, state, scope)
      assert input.name == "Eng"
      assert input.domain == "SE"
    end

    test "similar_roles is an :auto fork between :pick_template and :choose_starting_point" do
      similar = Enum.find(CreateFramework.steps(), &(&1.id == :similar_roles))

      assert similar.routing == :auto
      assert is_list(similar.next)

      ids = Enum.map(similar.next, & &1.to)
      assert :pick_template in ids
      assert :choose_starting_point in ids

      assert Enum.find(similar.next, &(&1.guard == :good_matches)).to == :pick_template

      assert Enum.find(similar.next, &(&1.guard == :no_similar_roles)).to ==
               :choose_starting_point

      assert Enum.all?(similar.next, &is_binary(&1.label))
    end

    test ":pick_template is a manual action with use_case PickTemplate, single-edge to :save" do
      pick = Enum.find(CreateFramework.steps(), &(&1.id == :pick_template))

      assert pick.type == :action
      assert pick.routing == :fixed
      assert pick.use_case == RhoFrameworks.UseCases.PickTemplate
      assert pick.next == :save
      assert pick.config[:manual] == true
      assert is_binary(pick.config[:message])
    end

    test "Deterministic walks the template path when the user selected a similar role", %{
      scope: scope
    } do
      state =
        FlowRunner.init(CreateFramework, intake: %{name: "Eng"})
        |> FlowRunner.put_summary(:similar_roles, %{
          matches: [%{id: "r1", name: "Backend"}],
          selected: [%{id: "r1", name: "Backend"}],
          skip_reason: nil
        })
        |> FlowRunner.advance(:similar_roles)

      similar = FlowRunner.current_node(state)

      assert {:ok, :pick_template, _} =
               FlowRunner.choose_next(CreateFramework, similar, state, Deterministic)

      _ = scope
    end

    test "Deterministic bounces back to :choose_starting_point when no role was selected", %{
      scope: scope
    } do
      state =
        FlowRunner.init(CreateFramework, intake: %{name: "Eng"})
        |> FlowRunner.put_summary(:similar_roles, %{
          matches: [%{id: "r1", name: "Backend"}],
          selected: [],
          skip_reason: "user skipped"
        })
        |> FlowRunner.advance(:similar_roles)

      similar = FlowRunner.current_node(state)

      assert {:ok, :choose_starting_point, _} =
               FlowRunner.choose_next(CreateFramework, similar, state, Deterministic)

      _ = scope
    end

    test "Deterministic routes :choose_starting_point→:similar_roles when starting_point is from_template",
         %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework,
          intake: %{name: "Eng", domain: "SE", starting_point: "from_template"}
        )
        |> FlowRunner.advance(:choose_starting_point)

      node = FlowRunner.current_node(state)

      assert {:ok, :similar_roles, _} =
               FlowRunner.choose_next(CreateFramework, node, state, Deterministic)

      _ = scope
    end

    test "Deterministic routes :choose_starting_point→:research when scratch guard fires",
         %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework,
          intake: %{name: "Mystery", description: "About", starting_point: "scratch"}
        )
        |> FlowRunner.advance(:choose_starting_point)

      node = FlowRunner.current_node(state)

      assert {:ok, :research, _} =
               FlowRunner.choose_next(CreateFramework, node, state, Deterministic)

      _ = scope
    end

    test "Deterministic routes :choose_starting_point→:research when scratch_intent fires even with populated intake",
         %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework,
          intake: %{
            name: "Eng",
            domain: "SE",
            target_roles: "Backend",
            starting_point: "scratch"
          }
        )
        |> FlowRunner.advance(:choose_starting_point)

      node = FlowRunner.current_node(state)

      # Explicit "scratch" form choice fires :scratch_intent → :research
      # regardless of whether domain/target_roles are populated.
      assert {:ok, :research, _} =
               FlowRunner.choose_next(CreateFramework, node, state, Deterministic)

      _ = scope
    end

    test "Deterministic falls through to :similar_roles when no intent guard matches",
         %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework,
          intake: %{
            name: "Eng",
            description: "About",
            domain: "SE",
            target_roles: "Backend"
          }
        )
        |> FlowRunner.advance(:choose_starting_point)

      node = FlowRunner.current_node(state)

      # No starting_point + populated intake → no intent guard fires,
      # implicit :scratch is also false → falls through to unguarded edge.
      assert {:ok, :similar_roles, _} =
               FlowRunner.choose_next(CreateFramework, node, state, Deterministic)

      _ = scope
    end

    test "build_input(:pick_template, ...) extracts ids from selected matches", %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework, intake: %{name: "Eng", description: "d"})
        |> FlowRunner.put_summary(:similar_roles, %{
          matches: [],
          selected: [%{id: "r1", name: "Backend"}, %{id: "r2", name: "Platform"}],
          skip_reason: nil
        })

      pick = Enum.find(CreateFramework.steps(), &(&1.id == :pick_template))
      input = FlowRunner.build_input(pick, state, scope)

      assert input.template_role_ids == ["r1", "r2"]
      assert input.intake.name == "Eng"
      assert input.intake.description == "d"
    end

    test "build_input(:save, ...) prefers :pick_template summary over :generate", %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework, intake: %{name: "Eng"})
        |> FlowRunner.put_summary(:pick_template, %{
          library_id: "lib-from-template",
          table_name: "library:Eng"
        })
        |> FlowRunner.put_summary(:generate, %{
          library_id: "lib-from-generate",
          table_name: "library:Eng"
        })

      save = Enum.find(CreateFramework.steps(), &(&1.id == :save))
      input = FlowRunner.build_input(save, state, scope)

      assert input.library_id == "lib-from-template"
      assert input.table_name == "library:Eng"
    end

    test "Deterministic routes :choose_starting_point→:pick_existing_library on extend_existing",
         %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework,
          intake: %{name: "Eng", starting_point: "extend_existing"}
        )
        |> FlowRunner.advance(:choose_starting_point)

      node = FlowRunner.current_node(state)

      assert {:ok, :pick_existing_library, _} =
               FlowRunner.choose_next(CreateFramework, node, state, Deterministic)

      _ = scope
    end

    test "Deterministic walks pick_existing_library → load_existing_library when picked", %{
      scope: scope
    } do
      state =
        FlowRunner.init(CreateFramework, intake: %{name: "Eng"})
        |> FlowRunner.put_summary(:pick_existing_library, %{
          matches: [%{id: "lib-1", name: "Old"}],
          selected: [%{id: "lib-1", name: "Old"}],
          skip_reason: nil
        })
        |> FlowRunner.advance(:pick_existing_library)

      node = FlowRunner.current_node(state)

      assert {:ok, :load_existing_library, _} =
               FlowRunner.choose_next(CreateFramework, node, state, Deterministic)

      _ = scope
    end

    test "Deterministic bounces pick_existing_library → choose_starting_point on no pick", %{
      scope: scope
    } do
      state =
        FlowRunner.init(CreateFramework, intake: %{name: "Eng"})
        |> FlowRunner.put_summary(:pick_existing_library, %{
          matches: [%{id: "lib-1", name: "Old"}],
          selected: [],
          skip_reason: "user skipped"
        })
        |> FlowRunner.advance(:pick_existing_library)

      node = FlowRunner.current_node(state)

      assert {:ok, :choose_starting_point, _} =
               FlowRunner.choose_next(CreateFramework, node, state, Deterministic)

      _ = scope
    end

    test "build_input(:load_existing_library, ...) extracts the picked library_id", %{
      scope: scope
    } do
      state =
        FlowRunner.init(CreateFramework, intake: %{name: "Eng"})
        |> FlowRunner.put_summary(:pick_existing_library, %{
          matches: [],
          selected: [%{id: "lib-7", name: "Old"}],
          skip_reason: nil
        })

      node = Enum.find(CreateFramework.steps(), &(&1.id == :load_existing_library))
      input = FlowRunner.build_input(node, state, scope)
      assert input.library_id == "lib-7"
    end

    test "build_input(:identify_gaps, ...) bundles intake + load summary", %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework,
          intake: %{
            name: "Backend PM",
            description: "PMs working backend",
            domain: "Software",
            target_roles: "Backend PM"
          }
        )
        |> FlowRunner.put_summary(:load_existing_library, %{
          library_id: "lib-7",
          library_name: "Old",
          table_name: "library:Old",
          skill_count: 12,
          role_count: 0
        })

      node = Enum.find(CreateFramework.steps(), &(&1.id == :identify_gaps))
      input = FlowRunner.build_input(node, state, scope)

      assert input.library_id == "lib-7"
      assert input.table_name == "library:Old"
      assert input.intake.name == "Backend PM"
      assert input.intake.target_roles == "Backend PM"
    end

    test "build_input(:generate, ...) switches to :gaps_only when extend summaries are present",
         %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework,
          intake: %{name: "Backend PM", description: "X"}
        )
        |> FlowRunner.put_summary(:load_existing_library, %{
          library_id: "lib-7",
          library_name: "Old",
          table_name: "library:Old",
          skill_count: 0,
          role_count: 0
        })
        |> FlowRunner.put_summary(:identify_gaps, %{
          gaps: [%{skill_name: "Caching", category: "Eng", rationale: "PMs"}],
          gap_count: 1,
          library_id: "lib-7",
          table_name: "library:Old"
        })

      node = Enum.find(CreateFramework.steps(), &(&1.id == :generate))
      input = FlowRunner.build_input(node, state, scope)

      assert input.scope == :gaps_only
      assert input.table_name == "library:Old"
      assert input.gaps == [%{skill_name: "Caching", category: "Eng", rationale: "PMs"}]
      # seed_skills comes from reading the table; with no DataTable running it's []
      assert input.seed_skills == []
    end

    test "build_input(:generate, ...) without extend summaries stays in default :full mode",
         %{scope: scope} do
      state = FlowRunner.init(CreateFramework, intake: %{name: "Eng"})

      node = Enum.find(CreateFramework.steps(), &(&1.id == :generate))
      input = FlowRunner.build_input(node, state, scope)

      refute Map.has_key?(input, :scope)
      refute Map.has_key?(input, :gaps)
      refute Map.has_key?(input, :seed_skills)
    end

    # ──────────────────────────────────────────────────────────────────
    # Phase 10c — merge_frameworks branch
    # ──────────────────────────────────────────────────────────────────

    test "Deterministic routes :choose_starting_point→:pick_two_libraries on merge intent",
         %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework,
          intake: %{name: "Eng", starting_point: "merge"}
        )
        |> FlowRunner.advance(:choose_starting_point)

      node = FlowRunner.current_node(state)

      assert {:ok, :pick_two_libraries, _} =
               FlowRunner.choose_next(CreateFramework, node, state, Deterministic)

      _ = scope
    end

    test "Deterministic walks pick_two_libraries → diff_frameworks when two are picked",
         %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework, intake: %{name: "Merged"})
        |> FlowRunner.put_summary(:pick_two_libraries, %{
          matches: [%{id: "lib-1"}, %{id: "lib-2"}],
          selected: [%{id: "lib-1"}, %{id: "lib-2"}],
          skip_reason: nil
        })
        |> FlowRunner.advance(:pick_two_libraries)

      node = FlowRunner.current_node(state)

      assert {:ok, :diff_frameworks, _} =
               FlowRunner.choose_next(CreateFramework, node, state, Deterministic)

      _ = scope
    end

    test "Deterministic bounces pick_two_libraries → choose_starting_point on too few picks",
         %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework, intake: %{name: "Merged"})
        |> FlowRunner.put_summary(:pick_two_libraries, %{
          matches: [%{id: "lib-1"}, %{id: "lib-2"}],
          selected: [%{id: "lib-1"}],
          skip_reason: nil
        })
        |> FlowRunner.advance(:pick_two_libraries)

      node = FlowRunner.current_node(state)

      assert {:ok, :choose_starting_point, _} =
               FlowRunner.choose_next(CreateFramework, node, state, Deterministic)

      _ = scope
    end

    test "build_input(:diff_frameworks, ...) extracts the two picked library ids",
         %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework, intake: %{name: "Merged"})
        |> FlowRunner.put_summary(:pick_two_libraries, %{
          matches: [],
          selected: [%{id: "lib-1"}, %{id: "lib-2"}],
          skip_reason: nil
        })

      node = Enum.find(CreateFramework.steps(), &(&1.id == :diff_frameworks))
      input = FlowRunner.build_input(node, state, scope)

      assert input.library_id_a == "lib-1"
      assert input.library_id_b == "lib-2"
    end

    test "build_input(:merge_frameworks, ...) bundles ids + intake.name as new_name",
         %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework, intake: %{name: "Merged Eng"})
        |> FlowRunner.put_summary(:pick_two_libraries, %{
          matches: [],
          selected: [%{id: "lib-1"}, %{id: "lib-2"}],
          skip_reason: nil
        })

      node = Enum.find(CreateFramework.steps(), &(&1.id == :merge_frameworks))
      input = FlowRunner.build_input(node, state, scope)

      assert input.library_id_a == "lib-1"
      assert input.library_id_b == "lib-2"
      assert input.new_name == "Merged Eng"
    end

    test "build_input(:save, ...) prefers :merge_frameworks summary over others",
         %{scope: scope} do
      state =
        FlowRunner.init(CreateFramework, intake: %{name: "Eng"})
        |> FlowRunner.put_summary(:pick_template, %{
          library_id: "lib-from-template",
          table_name: "library:Eng"
        })
        |> FlowRunner.put_summary(:merge_frameworks, %{
          library_id: "lib-from-merge",
          library_name: "Merged",
          table_name: "library:Merged",
          skill_count: 5
        })

      save = Enum.find(CreateFramework.steps(), &(&1.id == :save))
      input = FlowRunner.build_input(save, state, scope)

      assert input.library_id == "lib-from-merge"
      assert input.table_name == "library:Merged"
    end
  end
end
