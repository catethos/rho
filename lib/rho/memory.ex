defmodule Rho.Memory do
  @moduledoc """
  Behaviour for pluggable memory backends (storage concerns only).

  The default implementation is `Rho.Memory.Tape`, which wraps the existing
  tape system. Custom backends can implement this behaviour to provide
  alternative storage (vector DB, in-memory, external store, etc.).

  Journal capabilities (search, handoff, tools) are provided by mounts
  (e.g. `Rho.Mounts.JournalTools`) and call storage services directly.
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
  @callback compact_if_needed(memory_ref(), opts :: keyword()) :: {:ok, :not_needed} | {:ok, term()} | {:error, term()}
  @callback fork(memory_ref(), opts :: keyword()) :: {:ok, memory_ref()}
  @callback merge(fork_ref :: memory_ref(), main_ref :: memory_ref()) :: {:ok, integer()}
  @callback children(opts :: keyword()) :: [Supervisor.child_spec()]

  @optional_callbacks [compact_if_needed: 2, fork: 2, merge: 2, children: 1]
end
