defmodule Rho.TurnStrategy do
  @moduledoc """
  Behaviour for a single reason+act iteration driven by `Rho.Runner`.

  A TurnStrategy receives the current LLM context (messages + tools),
  calls the LLM, executes any tool calls (through the Transformer
  pipeline), and returns a tagged result telling the Runner whether to
  continue looping or stop.

  Strategies may also contribute their own prompt sections — see
  `c:prompt_sections/2`. The default is the empty list.

  ## Bundled strategies

  * `Rho.TurnStrategy.Direct` — native tool_use streaming (default)
  * `Rho.TurnStrategy.TypedStructured` — typed structured-JSON output
    using `Rho.ActionSchema` for tagged union dispatch

  `Rho.Reasoner` and its sub-modules remain as delegating aliases.
  """

  @type turn_result ::
          {:continue, map()}
          | {:done, map()}
          | {:final, term(), map()}
          | {:error, term()}

  @doc """
  Execute one reason+act iteration: call the LLM, execute any tool
  calls, return entries for the Runner to commit.
  """
  @callback run(projection :: map(), runtime :: map()) :: turn_result()

  @doc """
  Return prompt sections the strategy wants injected **after** plugin
  sections but **before** tape-derived messages. This is where format
  enforcement (JSON schema, XML tags, tagged-union instructions) lives
  so the LLM reads it last.
  """
  @callback prompt_sections(tool_defs :: [map()], context :: map()) ::
              [String.t() | Rho.PromptSection.t()]

  @optional_callbacks prompt_sections: 2
end
