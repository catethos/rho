defmodule RhoWeb.Projection do
  @moduledoc """
  Behaviour for pure signal-to-state reducers.

  Projections transform signal bus events into plain map state updates,
  with no dependency on `Phoenix.LiveView.Socket`. This makes them
  testable and replayable outside of a LiveView process.
  """

  @doc "Returns true if this projection handles the given event kind."
  @callback handles?(kind :: atom()) :: boolean()

  @doc "Returns the initial state map for this projection."
  @callback init() :: map()

  @doc "Reduces a signal into the current state, returning updated state."
  @callback reduce(state :: map(), signal :: map()) :: map()
end
