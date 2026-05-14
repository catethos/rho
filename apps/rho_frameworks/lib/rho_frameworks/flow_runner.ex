defmodule RhoFrameworks.FlowRunner do
  @moduledoc """
  Orchestrator for `RhoFrameworks.Flow`-shaped flows. Pulled out of
  `RhoWeb.FlowLive` so chat (and any future driver) can run the same
  flows.

  ## State

      %{
        flow_mod:      module(),
        node_id:       atom() | :done,
        intake:        map(),                # transient form values not in tables
        summaries:     %{atom() => map()},   # per-node UseCase return summaries
        user_override: %{atom() => atom()}   # node_id => chosen edge id (Hybrid short-circuit)
      }

  Anything table-shaped is read from `RhoFrameworks.Workbench.snapshot/1`,
  not held in runner state. The runner only owns the form intake and the
  small per-node summaries map (used for input building and edge guards).

  `choose_next/5` dispatches to a `RhoFrameworks.Flow.Policy` module
  (defaulting to `Deterministic` for tests; `FlowLive` passes it
  explicitly). The policy receives the normalized list of allowed edges
  derived from `current_node.next`; the runner does not pre-pick.
  """

  alias RhoFrameworks.{Flow, Scope, UseCase}

  @type state :: %{
          flow_mod: module(),
          node_id: atom() | :done,
          intake: map(),
          summaries: %{atom() => map()},
          user_override: %{atom() => atom()}
        }

  @type step :: Flow.node_def()

  @type next_decision :: %{reason: String.t() | nil, confidence: float() | nil}

  # ──────────────────────────────────────────────────────────────────────
  # Construction / state mutation
  # ──────────────────────────────────────────────────────────────────────

  @spec init(module(), keyword()) :: state()
  def init(flow_mod, opts \\ []) when is_atom(flow_mod) do
    start_id =
      case Keyword.get(opts, :start) do
        nil -> hd(flow_mod.steps()).id
        id when is_atom(id) -> id
      end

    %{
      flow_mod: flow_mod,
      node_id: start_id,
      intake: Keyword.get(opts, :intake, %{}),
      summaries: Keyword.get(opts, :summaries, %{}),
      user_override: Keyword.get(opts, :user_override, %{})
    }
  end

  @spec put_intake(state(), map()) :: state()
  def put_intake(state, intake) when is_map(intake), do: %{state | intake: intake}

  @spec put_user_override(state(), atom(), atom()) :: state()
  def put_user_override(state, node_id, edge_id)
      when is_atom(node_id) and is_atom(edge_id) do
    overrides = Map.get(state, :user_override, %{})
    %{state | user_override: Map.put(overrides, node_id, edge_id)}
  end

  @spec merge_intake(state(), map()) :: state()
  def merge_intake(state, partial) when is_map(partial) do
    %{state | intake: Map.merge(state.intake, partial)}
  end

  @spec put_summary(state(), atom(), map()) :: state()
  def put_summary(state, node_id, summary) when is_atom(node_id) and is_map(summary) do
    %{state | summaries: Map.put(state.summaries, node_id, summary)}
  end

  @spec advance(state(), atom()) :: state()
  def advance(state, next_id) when is_atom(next_id), do: %{state | node_id: next_id}

  @spec done?(state()) :: boolean()
  def done?(%{node_id: :done}), do: true
  def done?(_), do: false

  # ──────────────────────────────────────────────────────────────────────
  # Inspection
  # ──────────────────────────────────────────────────────────────────────

  @spec current_node(state()) :: step() | nil
  def current_node(%{flow_mod: mod, node_id: id}) when is_atom(id) and id != :done do
    Enum.find(mod.steps(), fn s -> s.id == id end)
  end

  def current_node(_), do: nil

  # ──────────────────────────────────────────────────────────────────────
  # Per-node input building
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Build the input map for the node's UseCase.

  Delegates to the flow module's optional `build_input/3` callback. If
  the flow doesn't define one, returns an empty map (UseCases are
  expected to validate their own inputs).
  """
  @spec build_input(step(), state(), Scope.t()) :: map()
  def build_input(%{id: id}, %{flow_mod: mod} = state, %Scope{} = scope) do
    if function_exported?(mod, :build_input, 3) do
      mod.build_input(id, state, scope)
    else
      %{}
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Run
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Run the node's UseCase. Returns the UseCase result, or
  `{:error, :no_use_case}` if the node has no `:use_case` field
  (e.g. form/table_review/manual nodes).
  """
  @spec run_node(step(), state(), Scope.t()) :: UseCase.result() | {:error, :no_use_case}
  def run_node(node, state, %Scope{} = scope) do
    case Map.get(node, :use_case) do
      mod when is_atom(mod) and not is_nil(mod) ->
        input = build_input(node, state, scope)
        mod.run(input, scope)

      _ ->
        {:error, :no_use_case}
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Edge selection
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Dispatches edge selection to the given `Flow.Policy` module. The
  policy receives the normalized list of allowed edges derived from
  `current_node.next` (single atom → one edge; list of `edge_def` →
  passed through). `:done` short-circuits with no policy call.
  """
  @spec choose_next(module(), step(), state(), module(), keyword()) ::
          {:ok, atom() | :done, next_decision()} | {:error, term()}
  def choose_next(flow_mod, current_node, state, policy, opts \\ [])
      when is_atom(policy) and not is_nil(policy) do
    case allowed_edges(current_node) do
      :done ->
        {:ok, :done, %{reason: nil, confidence: nil}}

      [] ->
        {:error, :no_outgoing_edges}

      edges when is_list(edges) ->
        policy.choose_next(flow_mod, current_node, state, edges, opts)
    end
  end

  @doc """
  Evaluate a named guard against runner state.

  Guards are referenced by `edge_def.guard` and let policies filter
  outgoing edges to the ones whose precondition is satisfied. They read
  only from `state` (intake + summaries); never side effects.

  Phase 4a clauses:

    * `:good_matches` — `summaries[:similar_roles]` was populated AND
      `matches` is non-empty AND `selected` is non-empty (user picked at
      least one similar role).
    * `:no_matches` — the negation of `:good_matches` (no summary, no
      matches, or user selected nothing).

  Phase 4b clauses:

    * `:scratch` — intake describes an unfamiliar domain: both `domain`
      and `target_roles` are blank/missing. Used on the intake fork to
      route into `:research` before the similar-roles lookup; falsy when
      the user has supplied any seed (we already have signal to feed
      `LoadSimilarRoles`).

  Phase 10a clauses:

    * `:from_template_intent` — the user picked "From a similar role" on
      the `:choose_starting_point` fork. Reads
      `intake[:starting_point] == "from_template"`. Form values are
      strings, so the comparison is string-on-string (no `String.to_atom`
      on user input — Iron Law #10).
    * `:scratch_intent` — the user picked "Start from scratch" on the
      `:choose_starting_point` fork. Reads
      `intake[:starting_point] == "scratch"`. Distinct from the implicit
      `:scratch` guard, which fires only when intake fields are blank;
      `:scratch_intent` honors the explicit form choice regardless of
      whether the user filled in domain/target_roles.
    * `:no_similar_roles` — alias of `:no_matches` semantics, used on
      the `:similar_roles` bounce edge back to `:choose_starting_point`.
      True when the LoadSimilarRoles summary is missing, the matches list
      is empty, or the user selected nothing.

  Phase 10b clauses (extend_existing branch):

    * `:extend_existing_intent` — mirrors `:from_template_intent`.
      Reads `intake[:starting_point] == "extend_existing"`.
    * `:existing_library_picked` — true when the user picked at least one
      library on the `:pick_existing_library` `:select` step
      (`summaries[:pick_existing_library].selected` non-empty).
    * `:no_existing_libraries` — bounce-back guard for
      `:pick_existing_library`; true when no library was picked (org has
      none, user skipped, or summary is missing).
    * `:loaded_with_proficiency` — true when
      `summaries[:load_existing_library].has_proficiency` is `true`.
      Used by `:edit-framework` to skip the `:confirm`+`:proficiency`
      pair when the loaded library's skills are already fully populated
      (e.g. forked from a published standard).
    * `:loaded_without_proficiency` — negation of `:loaded_with_proficiency`.
      Falls through to the `:confirm → :proficiency` regenerate path.

  Phase 10c clauses (merge_frameworks branch):

    * `:merge_intent` — mirrors `:from_template_intent`. Reads
      `intake[:starting_point] == "merge"`.
    * `:two_libraries_picked` — true when the user picked exactly two
      libraries on the `:pick_two_libraries` step
      (`summaries[:pick_two_libraries].selected` has length 2).
    * `:fewer_than_two_libraries` — bounce-back guard for
      `:pick_two_libraries`; true when fewer than two libraries were
      picked (not yet attempted, summary missing, or selection too small).

  Unknown names raise `ArgumentError` so a typo in a flow definition
  surfaces during testing rather than silently failing-open.
  """
  @spec guard?(atom(), state()) :: boolean()
  def guard?(:good_matches, state) do
    case state.summaries[:similar_roles] do
      %{matches: matches, selected: selected}
      when is_list(matches) and matches != [] and is_list(selected) and selected != [] ->
        true

      _ ->
        false
    end
  end

  def guard?(:no_matches, state), do: not guard?(:good_matches, state)

  def guard?(:no_similar_roles, state), do: not guard?(:good_matches, state)

  def guard?(:scratch, %{intake: intake}) when is_map(intake) do
    blank?(get_intake(intake, :domain)) and blank?(get_intake(intake, :target_roles))
  end

  def guard?(:scratch, _state), do: true

  def guard?(:from_template_intent, %{intake: intake}) when is_map(intake) do
    get_intake(intake, :starting_point) == "from_template"
  end

  def guard?(:from_template_intent, _state), do: false

  def guard?(:scratch_intent, %{intake: intake}) when is_map(intake) do
    get_intake(intake, :starting_point) == "scratch"
  end

  def guard?(:scratch_intent, _state), do: false

  def guard?(:extend_existing_intent, %{intake: intake}) when is_map(intake) do
    get_intake(intake, :starting_point) == "extend_existing"
  end

  def guard?(:extend_existing_intent, _state), do: false

  def guard?(:existing_library_picked, state) do
    case state.summaries[:pick_existing_library] do
      %{selected: selected} when is_list(selected) and selected != [] -> true
      _ -> false
    end
  end

  def guard?(:no_existing_libraries, state),
    do: not guard?(:existing_library_picked, state)

  def guard?(:loaded_with_proficiency, state) do
    case state.summaries[:load_existing_library] do
      %{has_proficiency: true} -> true
      _ -> false
    end
  end

  def guard?(:loaded_without_proficiency, state),
    do: not guard?(:loaded_with_proficiency, state)

  def guard?(:merge_intent, %{intake: intake}) when is_map(intake) do
    get_intake(intake, :starting_point) == "merge"
  end

  def guard?(:merge_intent, _state), do: false

  def guard?(:two_libraries_picked, state) do
    case state.summaries[:pick_two_libraries] do
      %{selected: [_, _]} -> true
      _ -> false
    end
  end

  def guard?(:fewer_than_two_libraries, state),
    do: not guard?(:two_libraries_picked, state)

  def guard?(name, _state) when is_atom(name) do
    raise ArgumentError, "unknown FlowRunner guard: #{inspect(name)}"
  end

  # Normalize node.next into a list of edge_def. Returns :done for
  # terminal nodes so callers can short-circuit without invoking a
  # policy.
  defp allowed_edges(%{next: :done}), do: :done
  defp allowed_edges(%{next: id}) when is_atom(id), do: [%{to: id, guard: nil, label: nil}]
  defp allowed_edges(%{next: edges}) when is_list(edges), do: edges

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?([]), do: true
  defp blank?(list) when is_list(list), do: Enum.all?(list, &blank?/1)
  defp blank?(_), do: false

  defp get_intake(intake, key) do
    Map.get(intake, key) || Map.get(intake, Atom.to_string(key))
  end
end
