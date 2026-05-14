defmodule Rho.Stdlib.Plugins.DebugTape do
  @moduledoc """
  Developer-only plugin for inspecting conversation traces.
  """

  @behaviour Rho.Plugin

  @impl Rho.Plugin
  def tools(_opts, _ctx), do: Rho.Stdlib.Tools.DebugTape.tool_defs()

  @impl Rho.Plugin
  def bindings(_opts, _ctx) do
    [
      %{
        name: "debug_tape",
        kind: :trace_index,
        access: :tool,
        persistence: :runtime,
        summary: "Developer-only access to recent conversation traces"
      }
    ]
  end

  @impl Rho.Plugin
  def prompt_sections(_opts, _ctx), do: []
end
