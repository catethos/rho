defmodule Rho.Reasoner do
  @moduledoc """
  Behaviour for a single reason+act iteration within the agent loop.

  A reasoner receives the current LLM context (messages + tools), calls
  the LLM, executes any tool calls, and returns a tagged result telling
  the agent loop whether to continue iterating or stop.

  The default implementation is `Rho.Reasoner.Direct`, which streams a
  response from the LLM, runs tool calls concurrently, and checks for
  terminal tools (finish, create_anchor, etc.).
  """

  @type turn_result ::
          {:continue, [map()]}
          | {:done, [map()]}
          | {:final, term(), [map()]}

  @doc """
  Executes one reason+act iteration: call the LLM, execute any tool calls,
  return entries for the turn engine to commit.

  ## Parameters
    * `projection` - map with `:context` (messages), `:tools` (ReqLLM tools), and `:step`
    * `runtime` - `%Rho.AgentLoop.Runtime{}` containing model, tools, emit, lifecycle, etc.

  ## Returns
    * `{:continue, entries}` - more steps needed, commit these entries
    * `{:done, entries}` - turn complete, commit these entries
    * `{:final, value, entries}` - explicit convergence (RLM FINAL())
  """
  @callback run(projection :: map(), runtime :: map()) :: turn_result()
end
