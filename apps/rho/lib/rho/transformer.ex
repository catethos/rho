defmodule Rho.Transformer do
  @moduledoc """
  Typed pipeline stages for in-flight mutation and control flow.

  A `Transformer` participates in one or more of six named stages that
  fire at fixed points in the agent loop. Each stage has a **typed
  contract** for both its input data shape and its allowed return
  shapes. Dialyzer enforces mis-typed implementations at compile time.

  ## Stages

    * `:prompt_out` — messages + system prompt about to be sent to the
      LLM. Use for PII scrub, policy gate, rate limit, token budget.
      Halt-capable.

    * `:response_in` — the LLM response (text, tool calls, usage)
      before it is acted upon. Use for toxicity filter, PII scrub on
      assistant output. Halt-capable.

    * `:tool_args_out` — a tool call's name and args about to be
      executed. Use for arg validation, secret redaction, **deny tool
      execution**. Halt-capable. Unique `{:deny, reason}` result.

    * `:tool_result_in` — a tool's result after execution, before it
      feeds back into the LLM. Use for output scrub, size cap,
      **result replacement**. Halt-capable.

    * `:post_step` — after each step completes (tool results
      appended). Use for synthetic message injection, post-step
      annotations, nudging the next turn. Halt-capable. Unique
      `{:inject, [message]}` result.

    * `:tape_write` — a tape entry about to be appended. Use for
      field encryption, retention tagging, redaction at rest.
      **Halt is disallowed** at this stage — the turn's side-effects
      have already fired, so refusing to record would leave the
      tape-as-recorded-reality invariant broken.

  ## Return shapes

  Each stage has its own union of allowed return shapes. See the
  `@type` aliases below for the full contracts. `{:cont, data}` passes
  (possibly mutated) data to the next transformer at the same stage.
  `{:halt, reason}` stops the turn. `{:deny, reason}` at
  `:tool_args_out` skips the tool call and appends a synthetic denial
  entry to the tape (turn continues). `{:inject, messages}` at
  `:post_step` appends the messages as user messages before the next
  turn.

  ## Registration

  Transformers register as plugins via `Rho.PluginRegistry.register/2`
  (a single module may implement both `@behaviour Rho.Plugin` and
  `@behaviour Rho.Transformer`). Priority comes from registration
  order — later registrations run first at each stage.
  """

  @type stage ::
          :prompt_out
          | :response_in
          | :tool_args_out
          | :tool_result_in
          | :post_step
          | :tape_write

  @type context :: map()
  @type message :: term()
  @type tool_call :: map()
  @type entry :: map()

  @type prompt_out_data :: %{messages: [message()], system: String.t() | nil}
  @type prompt_out_result :: {:cont, prompt_out_data()} | {:halt, term()}

  @type response_in_data :: %{text: String.t() | nil, tool_calls: [tool_call()], usage: map()}
  @type response_in_result :: {:cont, response_in_data()} | {:halt, term()}

  @type tool_args_data :: %{tool_name: String.t(), args: map()}
  @type tool_args_result ::
          {:cont, tool_args_data()} | {:deny, term()} | {:halt, term()}

  @type tool_result_data :: %{tool_name: String.t(), result: term()}
  @type tool_result_result :: {:cont, tool_result_data()} | {:halt, term()}

  @type post_step_data :: %{step: non_neg_integer(), entries_appended: [entry()]}
  @type post_step_result ::
          {:cont, nil} | {:inject, [message()]} | {:halt, term()}

  @type tape_write_data :: entry()
  @type tape_write_result :: {:cont, tape_write_data()}

  @type stage_result ::
          prompt_out_result()
          | response_in_result()
          | tool_args_result()
          | tool_result_result()
          | post_step_result()
          | tape_write_result()

  @doc """
  Transform data at the given stage.

  Transformers implement the stages they care about via pattern matching
  on the stage atom. Unmatched stages should return `{:cont, data}` —
  though in practice `Rho.PluginRegistry.apply_stage/3` only invokes
  `transform/3` on modules that export it, so transformers typically
  handle every stage they want to participate in explicitly.
  """
  @callback transform(stage(), data :: term(), context()) :: stage_result()

  @optional_callbacks transform: 3
end
