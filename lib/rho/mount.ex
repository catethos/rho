defmodule Rho.Mount do
  @moduledoc """
  Unified mount behaviour. A mount is anything attached to an agent process
  that contributes behavior or state to a turn.

  All callbacks are optional — a mount implements only what it needs.

  Callbacks are organized into two planes:

  - **Affordances** (tools, prompt_sections, bindings) — LLM-visible.
  - **Hooks** (before_llm, before_tool, after_tool, after_step) — invisible
    to the LLM, higher privilege. Used for policy, guardrails, and projection
    shaping. Must be side-effect-free on the journal (projection is ephemeral).
  """

  @type tool_def :: %{
          tool: ReqLLM.Tool.t(),
          execute: (map() -> {:ok, String.t()} | {:error, term()})
        }
  @type context :: map()
  @type mount_opts :: keyword()

  @type binding :: %{
          name: String.t(),
          kind: :text_corpus | :structured_data | :filesystem | :session_state,
          size: non_neg_integer(),
          access: :python_var | :tool | :resolver,
          persistence: :turn | :session | :derived,
          summary: String.t()
        }

  @type projection :: %{
          system_prompt: String.t(),
          messages: [map()],
          prompt_sections: [String.t()],
          bindings: [binding()],
          tools: [map()],
          meta: map()
        }

  # --- LLM-visible affordances ---

  @doc "Return tool definitions available in this turn."
  @callback tools(mount_opts(), context()) :: [tool_def()]

  @doc "Return prompt sections to append to the system prompt."
  @callback prompt_sections(mount_opts(), context()) :: [String.t() | Rho.Mount.PromptSection.t()]

  @doc """
  Return bindings — large resources exposed by reference rather than inline.
  The engine renders metadata (name, size, summary, access path) in the prompt;
  the agent accesses actual content programmatically via the specified access method.
  """
  @callback bindings(mount_opts(), context()) :: [binding()]

  # --- Invisible policy hooks ---

  @doc """
  Called immediately before each LLM provider call with the assembled projection.
  Returns the (possibly modified) projection. Must be side-effect-free.

  - `{:ok, projection}` — use as-is (default if not implemented)
  - `{:replace, projection}` — substitute the projection
  """
  @callback before_llm(projection(), mount_opts(), context()) ::
              {:ok, projection()} | {:replace, projection()}

  @doc """
  Called before a tool is executed. Return whether to allow the call.

  - `:ok` — allow the tool call (default if not implemented)
  - `{:deny, reason}` — block the call; reason is returned to the LLM as an error
  """
  @callback before_tool(call :: map(), mount_opts(), context()) ::
              :ok | {:deny, String.t()}

  @doc """
  Called after each tool execution. Return the effective result.

  - `{:ok, result}` — use as-is (default if not implemented)
  - `{:replace, new_result}` — substitute the tool result
  """
  @callback after_tool(call :: map(), result :: String.t(), mount_opts(), context()) ::
              {:ok, String.t()} | {:replace, String.t()}

  @doc """
  Called after each turn step (all tool calls in a step executed).

  - `:ok` — continue normally
  - `{:inject, message}` — inject a user-role message before the next LLM call
  - `{:inject, [messages]}` — inject multiple messages
  """
  @callback after_step(step :: integer(), max_steps :: integer(), mount_opts(), context()) ::
              :ok | {:inject, String.t() | [String.t()]}

  # --- Lifecycle ---

  @doc "Return OTP child specs for supervised resources this mount needs."
  @callback children(mount_opts(), context()) :: [Supervisor.child_spec()]

  @optional_callbacks tools: 2,
                      prompt_sections: 2,
                      bindings: 2,
                      before_llm: 3,
                      before_tool: 3,
                      after_tool: 4,
                      after_step: 4,
                      children: 2
end
