defmodule Rho.Debounce do
  @moduledoc """
  Per-session debounce GenServer. Buffers rapid messages and flushes
  a merged batch to a session after a configurable delay.

  Used by adapters that need debounce (e.g., Telegram). CLI and Web
  adapters do not use this.
  """
  use GenServer, restart: :transient
  require Logger

  defstruct [
    :debounce_key,
    :session_id,
    :debounce_ms,
    :max_wait_ms,
    :active_window_ms,
    :last_active_at,
    buffer: [],
    timer_ref: nil
  ]

  # --- Public API ---

  def start_link(opts) do
    debounce_key = Keyword.fetch!(opts, :debounce_key)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Rho.AgentRegistry, {:debounce, debounce_key}}}
    )
  end

  @doc "Buffer content for debounced delivery."
  def buffer(pid, content, opts \\ []) do
    GenServer.cast(pid, {:buffer, content, opts})
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       debounce_key: opts[:debounce_key],
       session_id: opts[:session_id],
       debounce_ms: opts[:debounce_ms] || 1_000,
       max_wait_ms: opts[:max_wait_ms] || 10_000,
       active_window_ms: opts[:active_window_ms] || 60_000
     }}
  end

  @impl true
  def handle_cast({:buffer, content, opts}, state) do
    now = System.monotonic_time(:millisecond)
    is_active = opts[:is_active] || false

    cond do
      # Active message — debounce with short timer
      is_active ->
        state = cancel_timer(state)
        timer_ref = Process.send_after(self(), :flush, state.debounce_ms)

        {:noreply,
         %{state | buffer: [content | state.buffer], timer_ref: timer_ref, last_active_at: now}}

      # Inactive within active window — use max_wait
      state.last_active_at && now - state.last_active_at < state.active_window_ms ->
        state =
          if state.timer_ref == nil do
            timer_ref = Process.send_after(self(), :flush, state.max_wait_ms)
            %{state | timer_ref: timer_ref}
          else
            state
          end

        {:noreply, %{state | buffer: [content | state.buffer]}}

      # Inactive outside active window — drop
      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    unless Enum.empty?(state.buffer) do
      merged = state.buffer |> Enum.reverse() |> Enum.join("\n")

      if pid = Rho.Agent.Primary.whereis(state.session_id) do
        Rho.Agent.Worker.submit(pid, merged)
      end
    end

    {:noreply, %{state | buffer: [], timer_ref: nil}}
  end

  # --- Private ---

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
