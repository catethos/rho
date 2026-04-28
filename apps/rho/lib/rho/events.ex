defmodule Rho.Events do
  @moduledoc """
  Session-scoped event transport over Phoenix.PubSub.

  Provides a single PubSub topic per session (`"rho:session:<sid>"`) plus
  a global lifecycle topic (`"rho:lifecycle"`) for agent start/stop events.
  Events are canonical `Rho.Events.Event` structs with atom `kind` fields.

  ## Usage

      # Subscribe (in mount, init, or any process)
      Rho.Events.subscribe(session_id)

      # Broadcast (from Worker.emit, EffectDispatcher, etc.)
      event = Rho.Events.normalize(emit_event, session_id, agent_id)
      Rho.Events.broadcast(session_id, event)

      # Receive (in handle_info)
      def handle_info(%Rho.Events.Event{kind: :text_delta} = e, state) do
        ...
      end

  ## Global lifecycle events

      Rho.Events.subscribe_lifecycle()

      def handle_info(%Rho.Events.Event{kind: :agent_stopped} = e, state) do
        ...
      end
  """

  alias Rho.Events.Event

  @pubsub Rho.PubSub
  @lifecycle_topic "rho:lifecycle"

  # -------------------------------------------------------------------
  # Session-scoped subscriptions
  # -------------------------------------------------------------------

  @doc "Subscribe the current process to all events for the given session."
  @spec subscribe(String.t()) :: :ok
  def subscribe(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(session_id))
  end

  @doc "Unsubscribe the current process from a session's events."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session_id) when is_binary(session_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(session_id))
  end

  @doc "Broadcast a canonical event to all subscribers of the session."
  @spec broadcast(String.t(), Event.t()) :: :ok | {:error, term()}
  def broadcast(session_id, %Event{} = event) when is_binary(session_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(session_id), event)
  end

  # -------------------------------------------------------------------
  # Global lifecycle subscriptions
  # -------------------------------------------------------------------

  @doc "Subscribe the current process to global agent lifecycle events."
  @spec subscribe_lifecycle() :: :ok
  def subscribe_lifecycle do
    Phoenix.PubSub.subscribe(@pubsub, @lifecycle_topic)
  end

  @doc "Broadcast an event to the global lifecycle topic."
  @spec broadcast_lifecycle(Event.t()) :: :ok | {:error, term()}
  def broadcast_lifecycle(%Event{} = event) do
    Phoenix.PubSub.broadcast(@pubsub, @lifecycle_topic, event)
  end

  # -------------------------------------------------------------------
  # Event constructors
  # -------------------------------------------------------------------

  @doc """
  Normalize a Runner emit event map into a canonical `Event` struct.

  The emit map has `%{type: atom(), ...}` — this converts the `:type`
  atom to `:kind` and attaches session/agent metadata.
  """
  @spec normalize(map(), String.t(), String.t()) :: Event.t()
  def normalize(%{type: type} = emit_event, session_id, agent_id)
      when is_atom(type) and is_binary(session_id) and is_binary(agent_id) do
    data =
      emit_event
      |> Map.delete(:type)
      |> Map.put(:session_id, session_id)
      |> Map.put(:agent_id, agent_id)

    %Event{
      kind: type,
      session_id: session_id,
      agent_id: agent_id,
      timestamp: System.monotonic_time(:millisecond),
      data: data
    }
  end

  @doc """
  Build a canonical event from a kind atom and data map.

  Use this for events that don't originate from Runner emit (e.g.
  agent lifecycle, task delegation, effect dispatches).
  """
  @spec event(atom(), String.t(), String.t() | nil, map()) :: Event.t()
  def event(kind, session_id, agent_id \\ nil, data \\ %{})
      when is_atom(kind) and is_binary(session_id) do
    # Inject session_id and agent_id into data so consumers (e.g. the LV
    # session_state reducer) see a consistent shape regardless of whether
    # an event came through `normalize/3` (runner emit) or this builder
    # (agent lifecycle, delegation, effect dispatches). `Map.put_new`
    # preserves any explicit value the caller already supplied.
    data =
      data
      |> Map.put_new(:session_id, session_id)
      |> Map.put_new(:agent_id, agent_id)

    %Event{
      kind: kind,
      session_id: session_id,
      agent_id: agent_id,
      timestamp: System.monotonic_time(:millisecond),
      data: data
    }
  end

  # -------------------------------------------------------------------
  # Topic helpers
  # -------------------------------------------------------------------

  @doc false
  def topic(session_id), do: "rho:session:#{session_id}"

  @doc false
  def lifecycle_topic, do: @lifecycle_topic
end
