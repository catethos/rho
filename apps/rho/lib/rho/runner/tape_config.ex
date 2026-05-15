defmodule Rho.Runner.TapeConfig do
  @moduledoc """
  Configuration for the tape, the persistent conversation log.

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
