defmodule Rho.Tape.Projection do
  @moduledoc """
  Builds LLM message context from a tape.

  This is the behaviour for the tape-context projection — the module that
  turns a durable tape into the message history consumed by the LLM. The
  default implementation is `Rho.Tape.Projection.JSONL`, which wraps the
  existing tape system. Custom implementations can plug in alternative
  storage (vector DB, in-memory, external store, etc.).

  Tape tool affordances (anchor, search, recall, clear) are provided by
  plugins (e.g. `Rho.Stdlib.Plugins.Tape`) and call storage services
  directly.
  """

  @type memory_ref :: term()
  @type entry_kind :: :message | :tool_call | :tool_result | :anchor | :event

  # --- Required ---
  @callback memory_ref(session_id :: String.t(), workspace :: String.t()) :: memory_ref()
  @callback bootstrap(memory_ref()) :: :ok | {:ok, term()}
  @callback append(memory_ref(), entry_kind(), payload :: map(), meta :: map()) :: {:ok, term()}
  @callback append_from_event(memory_ref(), event :: map()) :: :ok
  @callback build_context(memory_ref()) :: [map()]
  @callback info(memory_ref()) :: map()
  @callback history(memory_ref()) :: [map()]
  @callback reset(memory_ref(), opts :: keyword()) :: :ok

  # --- Optional ---
  @callback compact_if_needed(memory_ref(), opts :: keyword()) ::
              {:ok, :not_needed} | {:ok, term()} | {:error, term()}
  @callback fork(memory_ref(), opts :: keyword()) :: {:ok, memory_ref()}
  @callback merge(fork_ref :: memory_ref(), main_ref :: memory_ref()) :: {:ok, integer()}
  @callback children(opts :: keyword()) :: [Supervisor.child_spec()]

  @optional_callbacks [compact_if_needed: 2, fork: 2, merge: 2, children: 1]

  @doc """
  Build LLM message context from a tape using the configured projection module.

  Resolves the active module via `Rho.Config.tape_module/0` and calls
  `build_context/1` on it.
  """
  @spec build(memory_ref()) :: [map()]
  def build(tape_name) do
    Rho.Config.tape_module().build_context(tape_name)
  end
end
