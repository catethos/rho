defmodule Rho.Session.Handle do
  @moduledoc """
  Opaque handle returned by `Rho.Session.start/1`.

  Holds everything needed to interact with a running session —
  callers should treat it as opaque and pass it to `Rho.Session.*` functions.
  """

  @enforce_keys [:session_id, :primary_pid]
  defstruct [:session_id, :primary_pid, :emit]
end
