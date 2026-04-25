defmodule Rho.Tape.Context.Tape do
  @moduledoc """
  Deprecated — use `Rho.Tape.Projection.JSONL` instead.

  This module is retained as a backward-compatible alias.
  """

  @behaviour Rho.Tape.Projection

  defdelegate memory_ref(session_id, workspace), to: Rho.Tape.Projection.JSONL
  defdelegate bootstrap(tape_name), to: Rho.Tape.Projection.JSONL
  defdelegate append(tape_name, kind, payload, meta \\ %{}), to: Rho.Tape.Projection.JSONL
  defdelegate append_from_event(tape_name, event), to: Rho.Tape.Projection.JSONL
  defdelegate build_context(tape_name), to: Rho.Tape.Projection.JSONL
  defdelegate info(tape_name), to: Rho.Tape.Projection.JSONL
  defdelegate history(tape_name), to: Rho.Tape.Projection.JSONL
  defdelegate reset(tape_name, opts \\ []), to: Rho.Tape.Projection.JSONL
  defdelegate compact_if_needed(tape_name, opts), to: Rho.Tape.Projection.JSONL
  defdelegate fork(tape_name, opts), to: Rho.Tape.Projection.JSONL
  defdelegate merge(fork_tape, main_tape), to: Rho.Tape.Projection.JSONL
  defdelegate children(opts), to: Rho.Tape.Projection.JSONL
end
