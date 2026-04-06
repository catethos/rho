defmodule Rho.Stdlib.Plugins.Control do
  @moduledoc """
  Plugin that provides agent control tools: `finish` and `end_turn`.
  """

  @behaviour Rho.Plugin

  @impl Rho.Plugin
  def tools(_plugin_opts, _context) do
    [
      Rho.Stdlib.Tools.Finish.tool_def(),
      Rho.Stdlib.Tools.EndTurn.tool_def()
    ]
  end
end
