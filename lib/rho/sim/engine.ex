defmodule Rho.Sim.Engine do
  @moduledoc """
  Simulation engine — creates, steps, and runs simulations.
  """

  require Logger

  alias Rho.Sim.{Run, Accumulator}

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
