defmodule Rho.Test.ReloadableMount do
  @moduledoc """
  A mount module compiled to disk (test/support) so that
  `:code.purge/1` + `:code.delete/1` can simulate an unloaded
  module that `Code.ensure_loaded/1` can subsequently re-load.

  Used exclusively by the `MountRegistry.safe_call` regression test
  (ensures `Code.ensure_loaded/1` runs before `function_exported?/3`).
  """
  @behaviour Rho.Mount

  @impl true
  def tools(_opts, _ctx), do: [%{name: "reloadable_tool", description: "Reloadable"}]
end
