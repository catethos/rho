defmodule Rho.Tape.Context do
  @moduledoc """
  Deprecated — use `Rho.Tape.Projection` instead.

  This module is retained as a backward-compatible alias.
  """

  defdelegate build(tape_name), to: Rho.Tape.Projection
end
