defmodule Rho.Sim.Domain do
  @type actor_id :: term()
  @type state :: term()
  @type derived :: term()
  @type observation :: term()
  @type proposal :: term()
  @type rolls :: map()
  @type event :: map()

  # --- Required ---

  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @callback transition(
              state(),
              actions :: term(),
              rolls(),
              derived(),
              Rho.Sim.Context.t(),
              :rand.state()
            ) :: {:ok, state(), [event()], :rand.state()} | {:error, term()}

  # --- Optional (defaults provided by `use Rho.Sim.Domain`) ---

  @callback actors(state(), Rho.Sim.Context.t()) :: [actor_id()]
  @callback derive(state(), Rho.Sim.Context.t()) :: derived()
  @callback observe(actor_id(), state(), derived(), Rho.Sim.Context.t()) :: observation()
  @callback sample(state(), Rho.Sim.Context.t(), :rand.state()) :: {rolls(), :rand.state()}
  @callback resolve_actions(
              proposals :: %{optional(actor_id()) => proposal()},
              state(),
              derived(),
              rolls(),
              Rho.Sim.Context.t()
            ) :: term()
  @callback metrics(state(), derived(), Rho.Sim.Context.t()) :: map()
  @callback halt?(state(), derived(), Rho.Sim.Context.t()) :: boolean()
  @callback apply_intervention(state(), intervention :: term(), Rho.Sim.Context.t()) :: state()

  @optional_callbacks actors: 2, derive: 2, observe: 4, sample: 3,
                      resolve_actions: 5, metrics: 3, halt?: 3,
                      apply_intervention: 3

  defmacro __using__(_opts) do
    quote do
      @behaviour Rho.Sim.Domain

      def actors(_state, _ctx), do: []
      def derive(_state, _ctx), do: %{}
      def observe(_actor, state, derived, _ctx), do: %{state: state, derived: derived}
      def sample(_state, _ctx, rng), do: {%{}, rng}
      def resolve_actions(proposals, _state, _derived, _rolls, _ctx), do: proposals
      def metrics(_state, _derived, _ctx), do: %{}
      def halt?(_state, _derived, _ctx), do: false
      def apply_intervention(_state, intervention, _ctx) do
        raise "#{__MODULE__} does not implement apply_intervention/3 but received intervention: #{inspect(intervention)}"
      end

      defoverridable actors: 2, derive: 2, observe: 4, sample: 3,
                     resolve_actions: 5, metrics: 3, halt?: 3,
                     apply_intervention: 3
    end
  end
end
