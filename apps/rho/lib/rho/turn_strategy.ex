defmodule Rho.TurnStrategy do
  @moduledoc """
  Behaviour for a single reason+act iteration driven by `Rho.Runner`.

  A TurnStrategy receives the current LLM context (messages + tools),
  calls the LLM, classifies the response, and returns an **intent** —
  a tagged tuple telling the Runner what the LLM wants to do.

  The Runner then handles side effects: tool execution (via
  `Rho.ToolExecutor`), tape recording, context advancement, and
  looping. Strategies never execute tools directly.

  ## Intent types

      {:respond, text}                        — LLM responded with text, no tools
      {:call_tools, [tool_call], text | nil}  — LLM wants to call tools
      {:think, thought}                       — LLM wants to reason (structured output)
      {:parse_error, reason, raw_text}        — LLM output couldn't be parsed
      {:error, reason}                        — infrastructure error

  Where `tool_call` is `%{name: String.t(), args: map(), call_id: String.t()}`.
  Strategy-specific metadata (e.g. original ReqLLM.ToolCall structs) may
  be included under additional keys.

  ## Callbacks

  - `run/2` — required: call the LLM, return an intent
  - `build_tool_step/3` — required: build step entries from tool results
  - `prompt_sections/2` — optional: contribute prompt sections
  - `build_think_step/1` — optional: build step entries for a think action

  ## Bundled strategies

  * `Rho.TurnStrategy.Direct` — native tool_use streaming (default)
  * `Rho.TurnStrategy.TypedStructured` — typed structured-JSON output
    using `Rho.ActionSchema` for tagged union dispatch
  """

  @type tool_call :: %{
          name: String.t(),
          args: map(),
          call_id: String.t()
        }

  @type turn_result ::
          {:respond, String.t()}
          | {:call_tools, [tool_call()], String.t() | nil}
          | {:think, String.t()}
          | {:parse_error, term(), String.t()}
          | {:error, term()}

  @doc """
  Execute one reason+act iteration: call the LLM, classify the response,
  and return an intent for the Runner to execute.
  """
  @callback run(projection :: map(), runtime :: map()) :: turn_result()

  @doc """
  Build step entries from tool execution results.

  Called by Runner after `Rho.ToolExecutor.run/5` completes. The returned
  map must include `:type`, `:assistant_msg`, `:tool_results`, and
  `:tool_calls` keys for the Runner to record and advance context.

  May optionally include `:tool_meta` — a list of
  `%{call_id, name, status, error_type}` maps, one per tool result. When
  present, `Rho.Recorder` uses this to persist the real tool name plus
  `status`/`error_type` onto the `:tool_result` tape entry instead of a
  generic hardcoded `status: "ok"`.
  """
  @callback build_tool_step(
              tool_calls :: [tool_call()],
              results :: [map()],
              response_text :: String.t() | nil
            ) :: map()

  @doc """
  Return prompt sections the strategy wants injected **after** plugin
  sections but **before** tape-derived messages. This is where format
  enforcement (JSON schema, XML tags, tagged-union instructions) lives
  so the LLM reads it last.
  """
  @callback prompt_sections(tool_defs :: [map()], context :: map()) ::
              [String.t() | Rho.PromptSection.t()]

  @doc """
  Build step entries for a think action. Only needed by strategies that
  return `{:think, thought}` intents.
  """
  @callback build_think_step(thought :: String.t()) :: map()

  @optional_callbacks prompt_sections: 2, build_think_step: 1
end
