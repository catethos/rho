defmodule Rho.Comms do
  @moduledoc """
  Signal-based communication layer for inter-agent messaging.

  Wraps jido_signal with Rho-specific conventions. All coordination-plane
  code talks to Rho.Comms, never to jido_signal directly.
  """

  @type signal_type :: String.t()
  @type payload :: map()
  @type opts :: keyword()

  @callback publish(signal_type(), payload(), opts()) :: :ok | {:error, term()}
  @callback subscribe(pattern :: String.t(), opts()) :: {:ok, reference()}
  @callback unsubscribe(reference()) :: :ok
  @callback replay(pattern :: String.t(), opts()) :: {:ok, [map()]}

  @doc "Publish a signal to the bus."
  defdelegate publish(type, payload, opts \\ []), to: Rho.Comms.SignalBus

  @doc "Subscribe to signals matching a pattern."
  defdelegate subscribe(pattern, opts \\ []), to: Rho.Comms.SignalBus

  @doc "Unsubscribe from a subscription."
  defdelegate unsubscribe(ref), to: Rho.Comms.SignalBus

  @doc "Replay signals matching a pattern."
  defdelegate replay(pattern, opts \\ []), to: Rho.Comms.SignalBus
end
