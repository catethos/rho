defmodule Rho.Sim.Engine do
  @moduledoc """
  Simulation engine — creates, steps, and runs simulations.
  """

  require Logger

  alias Rho.Sim.{Run, Accumulator, Context, StepError}

  @type result :: {Run.t(), Accumulator.t()}

  @type step_result ::
          {:ok, result()}
          | {:halted, result()}
          | {:error,
             {non_neg_integer(), Rho.Sim.StepError.t(), Run.t(), Accumulator.t()}}

  @doc """
  Create a new simulation run from a domain module and options.

  ## Options

    * `:domain_opts` — keyword list passed to `domain.init/1` (default `[]`)
    * `:policies` — `%{actor_id => module | {module, opts}}` (default `%{}`)
    * `:max_steps` — hard step limit (default `100`)
    * `:seed` — integer RNG seed (default `0`)
    * `:interventions` — `%{step => [intervention]}` (default `%{}`)
    * `:params` — immutable user params forwarded to Context (default `%{}`)
  """
  @spec new(module(), keyword()) :: {:ok, result()} | {:error, term()}
  def new(domain, opts \\ []) do
    with :ok <- validate_domain(domain),
         policies <- normalize_policies(Keyword.get(opts, :policies, %{})),
         :ok <- validate_policies(policies),
         :ok <- warn_policies(domain, policies),
         {:ok, domain_state} <- call_domain_init(domain, Keyword.get(opts, :domain_opts, [])),
         {:ok, policy_states} <- init_policies(policies) do
      seed = Keyword.get(opts, :seed, 0)
      max_steps = Keyword.get(opts, :max_steps, 100)
      rng = :rand.seed_s(:exsss, {seed, 0, 0})
      run_id = "run_#{seed}_#{System.unique_integer([:positive])}"

      run = %Run{
        run_id: run_id,
        domain: domain,
        domain_state: domain_state,
        policies: policies,
        policy_states: policy_states,
        rng: rng,
        seed: seed,
        max_steps: max_steps,
        interventions: Keyword.get(opts, :interventions, %{}),
        params: Keyword.get(opts, :params, %{}),
        step: 0
      }

      {:ok, {run, %Accumulator{}}}
    end
  end

  @doc """
  Execute one step of the simulation.

  Follows the 13-step algorithm: build context, apply interventions, derive,
  actors, sample, observe+decide per actor, resolve actions, transition,
  metrics, accumulate, check halt, update run.
  """
  @spec step(result(), keyword()) :: step_result()
  def step(run_acc, opts \\ [])

  def step({%Run{} = run, %Accumulator{} = acc}, _opts) do
    domain = run.domain
    state = run.domain_state
    step_num = run.step

    # 1. Build context
    ctx = %Context{
      run_id: run.run_id,
      step: step_num,
      max_steps: run.max_steps,
      seed: run.seed,
      params: run.params
    }

    # 2. Apply interventions
    with {:ok, state} <- apply_interventions(domain, state, run.interventions, step_num, ctx),
         # 3. Derive
         {:ok, derived} <- safe_call(:derive, domain, fn -> domain.derive(state, ctx) end, step_num),
         # 4. Actors
         {:ok, actors} <- safe_call(:actors, domain, fn -> domain.actors(state, ctx) end, step_num),
         # 5. Sample
         {:ok, {rolls, rng}} <- safe_call(:sample, domain, fn -> domain.sample(state, ctx, run.rng) end, step_num),
         # 6. Observe + Decide for each actor
         {:ok, {proposals, policy_states}} <-
           run_actor_loop(domain, actors, state, derived, ctx, run.policies, run.policy_states, step_num),
         # 7. Resolve actions
         {:ok, actions} <-
           safe_call(:resolve, domain, fn -> domain.resolve_actions(proposals, state, derived, rolls, ctx) end, step_num),
         # 8. Transition
         {:ok, {next_state, events, rng}} <-
           call_transition(domain, state, actions, rolls, derived, ctx, rng, step_num),
         # 9. Metrics (uses pre-transition derived)
         {:ok, metrics} <-
           safe_call(:metrics, domain, fn -> domain.metrics(next_state, derived, ctx) end, step_num) do
      # 10. Update accumulator
      acc = %{acc | step_metrics: [{step_num, metrics} | acc.step_metrics]}

      trace_entry = %{events: events, state: next_state, derived: derived, actions: actions}
      acc = %{acc | trace: [{step_num, trace_entry} | acc.trace]}

      # 11. Check halt
      next_step = step_num + 1
      halted = next_step >= run.max_steps or safe_halt?(domain, next_state, derived, ctx)

      # 12. Update run
      run = %{run |
        domain_state: next_state,
        rng: rng,
        step: next_step,
        policy_states: policy_states
      }

      # 13. Return
      if halted do
        {:halted, {run, acc}}
      else
        {:ok, {run, acc}}
      end
    else
      {:error, %StepError{} = err} ->
        {:error, {step_num, err, run, acc}}
    end
  end

  # --- Private step helpers ---

  defp apply_interventions(domain, state, interventions, step_num, ctx) do
    case Map.get(interventions, step_num) do
      nil ->
        {:ok, state}

      intervention_list ->
        try do
          result =
            Enum.reduce(intervention_list, state, fn intervention, s ->
              domain.apply_intervention(s, intervention, ctx)
            end)

          {:ok, result}
        rescue
          e ->
            {:error, %StepError{
              step: step_num,
              phase: :intervention,
              module: domain,
              reason: e,
              stacktrace: __STACKTRACE__
            }}
        end
    end
  end

  defp safe_call(phase, module, fun, step_num) do
    try do
      {:ok, fun.()}
    rescue
      e ->
        {:error, %StepError{
          step: step_num,
          phase: phase,
          module: module,
          reason: e,
          stacktrace: __STACKTRACE__
        }}
    end
  end

  defp call_transition(domain, state, actions, rolls, derived, ctx, rng, step_num) do
    try do
      case domain.transition(state, actions, rolls, derived, ctx, rng) do
        {:ok, next_state, events, new_rng} ->
          {:ok, {next_state, events, new_rng}}

        {:error, reason} ->
          {:error, %StepError{
            step: step_num,
            phase: :transition,
            module: domain,
            reason: reason
          }}
      end
    rescue
      e ->
        {:error, %StepError{
          step: step_num,
          phase: :transition,
          module: domain,
          reason: e,
          stacktrace: __STACKTRACE__
        }}
    end
  end

  defp run_actor_loop(_domain, [], _state, _derived, _ctx, _policies, policy_states, _step_num) do
    {:ok, {%{}, policy_states}}
  end

  defp run_actor_loop(domain, actors, state, derived, ctx, policies, policy_states, step_num) do
    Enum.reduce_while(actors, {:ok, {%{}, policy_states}}, fn actor, {:ok, {proposals, ps}} ->
      # Validate actor has a policy
      case Map.get(policies, actor) do
        nil ->
          err = %StepError{
            step: step_num,
            phase: :decide,
            actor: actor,
            reason: "no policy registered for actor #{inspect(actor)}"
          }

          {:halt, {:error, err}}

        {policy_mod, _policy_opts} ->
          # 6a. Observe
          case safe_call(:observe, domain, fn -> domain.observe(actor, state, derived, ctx) end, step_num) do
            {:ok, obs} ->
              # 6b. Decide
              policy_state = Map.get(ps, actor)

              case call_decide(policy_mod, actor, obs, ctx, policy_state, step_num) do
                {:ok, proposal, new_policy_state} ->
                  {:cont, {:ok, {Map.put(proposals, actor, proposal), Map.put(ps, actor, new_policy_state)}}}

                {:error, %StepError{} = err} ->
                  {:halt, {:error, err}}
              end

            {:error, %StepError{} = err} ->
              {:halt, {:error, %{err | actor: actor}}}
          end
      end
    end)
  end

  defp call_decide(policy_mod, actor, obs, ctx, policy_state, step_num) do
    try do
      case policy_mod.decide(actor, obs, ctx, policy_state) do
        {:ok, proposal, new_state} ->
          {:ok, proposal, new_state}

        {:error, reason} ->
          {:error, %StepError{
            step: step_num,
            phase: :decide,
            actor: actor,
            module: policy_mod,
            reason: reason
          }}
      end
    rescue
      e ->
        {:error, %StepError{
          step: step_num,
          phase: :decide,
          actor: actor,
          module: policy_mod,
          reason: e,
          stacktrace: __STACKTRACE__
        }}
    end
  end

  defp safe_halt?(domain, state, derived, ctx) do
    try do
      domain.halt?(state, derived, ctx)
    rescue
      _ -> false
    end
  end

  # --- Private helpers ---

  defp validate_domain(domain) do
    cond do
      not is_atom(domain) ->
        {:error, "domain must be an atom, got: #{inspect(domain)}"}

      not Code.ensure_loaded?(domain) ->
        {:error, "#{inspect(domain)} is not a loaded module"}

      not function_exported?(domain, :init, 1) ->
        {:error, "#{inspect(domain)} does not export init/1 — not a valid Domain"}

      not function_exported?(domain, :transition, 6) ->
        {:error, "#{inspect(domain)} does not export transition/6 — not a valid Domain"}

      true ->
        :ok
    end
  end

  defp normalize_policies(policies) when is_map(policies) do
    Map.new(policies, fn
      {actor_id, {mod, opts}} when is_atom(mod) and is_list(opts) -> {actor_id, {mod, opts}}
      {actor_id, mod} when is_atom(mod) -> {actor_id, {mod, []}}
    end)
  end

  defp validate_policies(policies) do
    Enum.reduce_while(policies, :ok, fn {actor_id, {mod, _opts}}, :ok ->
      cond do
        not Code.ensure_loaded?(mod) ->
          {:halt, {:error, "policy for #{inspect(actor_id)}: #{inspect(mod)} is not a loaded module"}}

        not function_exported?(mod, :decide, 4) ->
          {:halt, {:error, "policy for #{inspect(actor_id)}: #{inspect(mod)} does not export decide/4 — not a valid Policy"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp warn_policies(_domain, policies) when map_size(policies) == 0, do: :ok

  defp warn_policies(_domain, _policies) do
    Logger.warning(
      "Policies provided but domain's actors/2 may return [] — " <>
        "ensure domain implements actors/2 to return actor IDs"
    )

    :ok
  end

  defp call_domain_init(domain, opts) do
    case domain.init(opts) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, "domain init failed: #{inspect(reason)}"}
    end
  end

  defp init_policies(policies) do
    Enum.reduce_while(policies, {:ok, %{}}, fn {actor_id, {mod, opts}}, {:ok, acc} ->
      result =
        if function_exported?(mod, :init, 2) do
          mod.init(actor_id, opts)
        else
          {:ok, nil}
        end

      case result do
        {:ok, state} ->
          {:cont, {:ok, Map.put(acc, actor_id, state)}}

        {:error, reason} ->
          {:halt, {:error, "policy init failed for #{inspect(actor_id)}: #{inspect(reason)}"}}
      end
    end)
  end
end
