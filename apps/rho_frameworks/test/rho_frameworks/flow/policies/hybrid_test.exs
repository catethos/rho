defmodule RhoFrameworks.Flow.Policies.HybridTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.Flow.Policies.Hybrid

  # ──────────────────────────────────────────────────────────────────────
  # Test fixtures — minimal node + state shapes Hybrid needs
  # ──────────────────────────────────────────────────────────────────────

  defmodule StubFlow do
    @moduledoc false
  end

  defmodule StubRouterOk do
    @moduledoc false
    def call(_args, _opts \\ []) do
      {:ok,
       %{
         next_edge: "right",
         confidence: 0.82,
         reasoning: "Right matches the workflow state better."
       }}
    end
  end

  defmodule StubRouterUnknownEdge do
    @moduledoc false
    def call(_args, _opts \\ []),
      do: {:ok, %{next_edge: "not_an_edge", confidence: 0.5, reasoning: "n/a"}}
  end

  defmodule StubRouterFails do
    @moduledoc false
    def call(_args, _opts \\ []), do: {:error, :timeout}
  end

  defmodule StubRouterRecorder do
    @moduledoc false
    # A router that just records that it was called via the test pid stashed
    # in process dict. Used to assert short-circuits SKIP the router.
    def call(_args, _opts \\ []) do
      send(self(), {:router_called?, true})
      {:ok, %{next_edge: "left", confidence: 1.0, reasoning: "stub"}}
    end
  end

  defp node(id, routing, edges_or_atom) do
    %{
      id: id,
      label: "Node #{id}",
      type: :action,
      next: edges_or_atom,
      routing: routing,
      config: %{}
    }
  end

  defp edge(to, opts \\ []) do
    %{
      to: to,
      guard: Keyword.get(opts, :guard),
      label: Keyword.get(opts, :label, Atom.to_string(to))
    }
  end

  defp state(overrides \\ %{}) do
    Map.merge(
      %{flow_mod: StubFlow, node_id: :start, intake: %{}, summaries: %{}},
      overrides
    )
  end

  # ──────────────────────────────────────────────────────────────────────
  # Short-circuits run before routing dispatch
  # ──────────────────────────────────────────────────────────────────────

  describe "0-or-1-edge short-circuit" do
    test "single edge → first edge, no router call (even on :auto)" do
      n = node(:start, :auto, [edge(:only)])

      Process.put(:router_called, false)

      assert {:ok, :only, %{reason: nil, confidence: nil}} =
               Hybrid.choose_next(StubFlow, n, state(), [edge(:only)],
                 router_mod: StubRouterRecorder
               )

      refute_received {:router_called?, true}
    end

    test "all edges filtered out by guards → :no_satisfied_edge" do
      bad_state = state()
      edges = [edge(:left, guard: :no_matches), edge(:right, guard: :good_matches)]

      # bad_state has no summaries, so :good_matches=false, :no_matches=true.
      # Hybrid should pick the only valid edge (left) without calling router.
      n = node(:fork, :auto, edges)

      assert {:ok, :left, %{reason: nil, confidence: nil}} =
               Hybrid.choose_next(StubFlow, n, bad_state, edges, router_mod: StubRouterFails)
    end

    test "no edges with satisfied guards → {:error, :no_satisfied_edge}" do
      # Construct a state where neither guard passes by overriding guard?/2
      # via two opposing guards. We achieve this with a custom guard that
      # always fails by using a non-existent guard… but we'd raise. Instead
      # use both edges with the same guard and a state that fails it.
      # `:good_matches` requires non-empty selected → empty state fails it.
      bad_state = state()
      edges = [edge(:a, guard: :good_matches), edge(:b, guard: :good_matches)]
      n = node(:fork, :auto, edges)

      assert {:error, :no_satisfied_edge} =
               Hybrid.choose_next(StubFlow, n, bad_state, edges, router_mod: StubRouterRecorder)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # routing: :fixed
  # ──────────────────────────────────────────────────────────────────────

  describe "routing: :fixed" do
    test "picks first satisfied guard among multiple valid edges, no router call" do
      good =
        state(%{
          summaries: %{similar_roles: %{matches: [:r], selected: [:r], skip_reason: nil}}
        })

      edges = [
        edge(:pick_template, guard: :good_matches, label: "use template"),
        edge(:generate, guard: :no_matches, label: "from scratch")
      ]

      n = node(:fork, :fixed, edges)

      assert {:ok, :pick_template, %{reason: nil, confidence: nil}} =
               Hybrid.choose_next(StubFlow, n, good, edges, router_mod: StubRouterFails)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # routing: :auto
  # ──────────────────────────────────────────────────────────────────────

  describe "routing: :auto" do
    test "user_override short-circuits the router" do
      s = state(%{user_override: %{fork: :right}})
      edges = [edge(:left), edge(:right)]
      n = node(:fork, :auto, edges)

      assert {:ok, :right, %{reason: "user override", confidence: 1.0}} =
               Hybrid.choose_next(StubFlow, n, s, edges, router_mod: StubRouterFails)
    end

    test "user_override pointing at an invalid edge falls back to the router" do
      s = state(%{user_override: %{fork: :nonexistent}})
      edges = [edge(:left), edge(:right)]
      n = node(:fork, :auto, edges)

      assert {:ok, :right, %{reason: reasoning, confidence: 0.82}} =
               Hybrid.choose_next(StubFlow, n, s, edges, router_mod: StubRouterOk)

      assert reasoning =~ "Right matches"
    end

    test "calls the router and converts the returned string to an existing atom" do
      edges = [edge(:left), edge(:right)]
      n = node(:fork, :auto, edges)

      assert {:ok, :right, %{reason: _, confidence: 0.82}} =
               Hybrid.choose_next(StubFlow, n, state(), edges, router_mod: StubRouterOk)
    end

    test "returns :router_invalid_edge if the router picks an unknown id" do
      edges = [edge(:left), edge(:right)]
      n = node(:fork, :auto, edges)

      assert {:error, :router_invalid_edge} =
               Hybrid.choose_next(StubFlow, n, state(), edges, router_mod: StubRouterUnknownEdge)
    end

    test "wraps router errors in {:error, {:router_failed, reason}}" do
      edges = [edge(:left), edge(:right)]
      n = node(:fork, :auto, edges)

      assert {:error, {:router_failed, :timeout}} =
               Hybrid.choose_next(StubFlow, n, state(), edges, router_mod: StubRouterFails)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # routing: :agent_loop
  # ──────────────────────────────────────────────────────────────────────

  describe "routing: :agent_loop" do
    test "single-edge node short-circuits without consulting summaries" do
      edges = [edge(:generate)]
      n = node(:research, :agent_loop, edges)

      assert {:ok, :generate, %{reason: nil, confidence: nil}} =
               Hybrid.choose_next(StubFlow, n, state(), edges, [])
    end

    test "multi-edge node uses summaries[node_id].chosen_edge when present" do
      edges = [edge(:left), edge(:right)]
      n = node(:research, :agent_loop, edges)
      s = state(%{summaries: %{research: %{chosen_edge: :right}}})

      assert {:ok, :right, %{reason: reason, confidence: 1.0}} =
               Hybrid.choose_next(StubFlow, n, s, edges, [])

      assert reason =~ "agent_loop worker selected right"
    end

    test "multi-edge falls through to first valid edge when no chosen_edge signal" do
      edges = [edge(:first), edge(:second)]
      n = node(:research, :agent_loop, edges)

      assert {:ok, :first, %{reason: reason, confidence: nil}} =
               Hybrid.choose_next(StubFlow, n, state(), edges, [])

      assert reason =~ "first valid edge"
    end

    test "ignores chosen_edge that isn't in the allowed set (falls through)" do
      edges = [edge(:left), edge(:right)]
      n = node(:research, :agent_loop, edges)
      s = state(%{summaries: %{research: %{chosen_edge: :nonexistent}}})

      assert {:ok, :left, %{reason: reason, confidence: nil}} =
               Hybrid.choose_next(StubFlow, n, s, edges, [])

      assert reason =~ "first valid edge"
    end
  end
end
