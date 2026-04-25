defmodule RhoWeb.LiveEvents do
  @moduledoc """
  Session-scoped event transport over Phoenix.PubSub.

  Replaces the Jido.Signal bus wildcard subscriptions with a single
  PubSub topic per session: `"rho_lv:session:<sid>"`. Events are
  canonical structs (`RhoWeb.LiveEvents.Event`) with atom `kind`
  fields instead of dotted-string topics.

  ## Usage

      # Subscribe (in mount or subscribe_and_hydrate)
      RhoWeb.LiveEvents.subscribe(session_id)

      # Broadcast (from Worker.emit, EffectDispatcher, etc.)
      event = RhoWeb.LiveEvents.normalize(emit_event, session_id, agent_id)
      RhoWeb.LiveEvents.broadcast(session_id, event)

      # Receive (in handle_info)
      def handle_info(%RhoWeb.LiveEvents.Event{kind: :text_delta} = e, socket) do
        ...
      end

  Phase 1 creates this module as a pure addition. Nothing consumes it
  yet — Phase 2 wires dual-path delivery.
  """

  alias RhoWeb.LiveEvents.Event

  @pubsub Rho.PubSub

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
    %Event{
      kind: kind,
      session_id: session_id,
      agent_id: agent_id,
      timestamp: System.monotonic_time(:millisecond),
      data: data
    }
  end

  @doc false
  def topic(session_id), do: "rho_lv:session:#{session_id}"
end
