defmodule Rho.AgentLoop.Tape do
  @moduledoc """
  Configuration for the tape — the persistent conversation log.

  A tape records every message, tool call, and tool result so that context
  can be rebuilt across turns or after compaction. The `name` identifies the
  tape instance, `memory_mod` is the storage backend (default:
  `Rho.Tape.Projection.JSONL`), and `compact_threshold` controls when automatic
  summarization triggers.

  When `name` is `nil`, no tape recording occurs and context lives only
  in-memory for the current loop invocation.
  """

  defstruct name: nil,
            tape_module: Rho.Tape.Projection.JSONL,
            compact_threshold: 100_000,
            compact_supported: false

  @type t :: %__MODULE__{
          name: String.t() | nil,
          tape_module: module(),
          compact_threshold: pos_integer(),
          compact_supported: boolean()
        }
end
