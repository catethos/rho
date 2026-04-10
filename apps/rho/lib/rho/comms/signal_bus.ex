defmodule Rho.Comms.SignalBus do
  @moduledoc """
  Default Rho.Comms implementation backed by Jido.Signal.Bus.

  Starts a named signal bus (:rho_bus) and wraps publish/subscribe/replay
  with Rho-specific conventions.
  """

  use GenServer

  require Logger

  @bus_name :rho_bus

  # --- Lifecycle ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case Jido.Signal.Bus.start_link(name: @bus_name) do
      {:ok, pid} ->
        Process.link(pid)
        {:ok, %{bus_pid: pid}}

      {:error, {:already_started, pid}} ->
        {:ok, %{bus_pid: pid}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # --- Public API ---

  @doc "Publish a signal to the bus."
  def publish(type, payload, opts \\ []) do
    signal_attrs = %{source: Keyword.get(opts, :source, "/rho")}

    signal_attrs =
      case Keyword.get(opts, :subject) do
        nil -> signal_attrs
        subject -> Map.put(signal_attrs, :subject, subject)
      end

    # Build extensions with required metadata + optional correlation/causation
    extensions = %{
      "emitted_at" => System.system_time(:millisecond)
    }

    {cor, cau} = {Keyword.get(opts, :correlation_id), Keyword.get(opts, :causation_id)}
    extensions = if cor, do: Map.put(extensions, "correlation_id", cor), else: extensions
    extensions = if cau, do: Map.put(extensions, "causation_id", cau), else: extensions

    signal_attrs = Map.put(signal_attrs, :extensions, extensions)

    with {:ok, signal} <- Jido.Signal.new(type, payload, signal_attrs),
         {:ok, _recorded} <- Jido.Signal.Bus.publish(@bus_name, [signal]) do
      :ok
    end
  end

  @doc """
  Subscribe to signals matching a pattern.

  The subscriber process will receive `{:signal, %Jido.Signal{}}` messages.
  """
  def subscribe(pattern, opts \\ []) do
    target = Keyword.get(opts, :target, self())

    dispatch_opts = {:pid, target: target, delivery_mode: :async}

    case Jido.Signal.Bus.subscribe(@bus_name, pattern, dispatch: dispatch_opts) do
      {:ok, sub_id} ->
        {:ok, sub_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Unsubscribe from a subscription."
  def unsubscribe(sub_id) do
    Jido.Signal.Bus.unsubscribe(@bus_name, sub_id)
  end

  @doc "Replay signals matching a pattern."
  def replay(pattern, opts \\ []) do
    since = Keyword.get(opts, :since, 0)
    Jido.Signal.Bus.replay(@bus_name, pattern, since)
  end

  @doc "Returns the bus name for direct access if needed."
  def bus_name, do: @bus_name
end
