defmodule Rho.Sim.Policy do
  @type actor_id :: term()
  @type observation :: term()
  @type proposal :: term()
  @type state :: term()

  @callback decide(
              actor_id(),
              observation(),
              Rho.Sim.Context.t(),
              state()
            ) :: {:ok, proposal(), state()} | {:error, term()}

  @callback init(actor_id(), opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @optional_callbacks init: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour Rho.Sim.Policy

      def init(_actor_id, _opts), do: {:ok, nil}

      defoverridable init: 2
    end
  end
end
