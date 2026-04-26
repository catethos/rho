defmodule Rho.Stdlib.Transformers.SubagentNudge do
  @moduledoc """
  Keeps subagents looping toward `finish`.

  When an agent at `depth > 0` produces a text-only response (no tool
  calls), this transformer injects a "continue working" message via
  the `:post_step` stage so the loop continues until the subagent
  calls `finish`.

  No-op for primary agents (depth 0) and for tool/think steps at any
  depth — those advance the loop naturally without a nudge.

  Registered globally by `Rho.Stdlib.Application.start/2`. The depth
  gate makes global scope safe — primary agents pay nothing.
  """

  @behaviour Rho.Transformer

  @nudge "[System] Continue working on your task. Call `finish` with your result when done."

  @impl Rho.Transformer
  def transform(:post_step, %{step_kind: :text_response}, %{depth: depth})
      when is_integer(depth) and depth > 0 do
    {:inject, [@nudge]}
  end

  def transform(_stage, data, _context), do: {:cont, data}
end
