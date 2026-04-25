defmodule Rho.Plugin do
  @moduledoc """
  Capability contribution behaviour.

  A plugin contributes LLM-visible material to a turn: tools, prompt
  sections, and/or bindings. All callbacks are optional; a plugin
  implements only what it provides.

  Each callback takes `(opts, context)` — per-instance opts come from
  the plugin registration (e.g. `{:multi_agent, except: [...]}`).

  Hooks (policy, denial, injection) are out of scope for this
  behaviour — they live on `Rho.Transformer`.
  """

  @type tool_def :: %{
          tool: ReqLLM.Tool.t(),
          execute: (map(), context() -> {:ok, String.t()} | {:error, term()})
        }

  @type binding :: %{
          name: String.t(),
          kind: :text_corpus | :structured_data | :filesystem | :session_state,
          size: non_neg_integer(),
          access: :python_var | :tool | :resolver,
          persistence: :turn | :session | :derived,
          summary: String.t()
        }

  @type context :: map()
  @type plugin_opts :: keyword()

  @doc "Return tool definitions available in this turn."
  @callback tools(plugin_opts(), context()) :: [tool_def()]

  @doc "Return prompt sections to append to the system prompt."
  @callback prompt_sections(plugin_opts(), context()) ::
              [String.t() | Rho.PromptSection.t()]

  @doc """
  Return bindings — large resources exposed by reference rather than inline.
  The engine renders metadata (name, size, summary, access path) in the prompt;
  the agent accesses actual content programmatically via the specified access method.
  """
  @callback bindings(plugin_opts(), context()) :: [binding()]

  @optional_callbacks tools: 2, prompt_sections: 2, bindings: 2
end
