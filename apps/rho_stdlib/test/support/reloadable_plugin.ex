defmodule Rho.Test.ReloadablePlugin do
  @moduledoc """
  A plugin module compiled to disk (test/support) so that
  `:code.purge/1` + `:code.delete/1` can simulate an unloaded
  module that `Code.ensure_loaded/1` can subsequently re-load.

  Used exclusively by the `PluginRegistry.safe_call` regression test
  (ensures `Code.ensure_loaded/1` runs before `function_exported?/3`).
  """
  @behaviour Rho.Plugin

  @impl true
  def tools(_opts, _ctx), do: [%{name: "reloadable_tool", description: "Reloadable"}]
end
