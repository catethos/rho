defmodule Rho do
  @moduledoc """
  Rho — an Elixir-based AI agent framework.

  The core runtime provides: Runner, TurnStrategy, Tape, Plugin,
  Transformer, Agent, and Comms abstractions.

  ## Quick start

      {:ok, text} = Rho.run("hello")

  """

  @doc """
  One-shot agent interaction — start a session, send a message, stop, return the result.

  Accepts the same options as `Rho.Session.start/1`.
  """
  def run(message, opts \\ []) do
    {:ok, session} = Rho.Session.start(opts)

    try do
      Rho.Session.send(session, message)
    after
      Rho.Session.stop(session)
    end
  end
end
