defmodule Rho.Stdlib.Plugins.StepBudget do
  @moduledoc """
  Plugin that prevents runaway agent loops by:

  1. Injecting an `end_turn` tool that signals the loop to stop
  2. Injecting a step-budget reminder after each tool execution step,
     nudging the model to call `end_turn` when the task is done

  Only applies to top-level agents (depth 0). Subagents use `finish` instead.

  The reminder is delivered as a `Rho.Transformer` `:post_step`
  injection.
  """

  @behaviour Rho.Plugin
  @behaviour Rho.Transformer

  @impl Rho.Plugin
  def tools(_plugin_opts, %{depth: depth}) when depth > 0, do: []
  def tools(_plugin_opts, _context), do: [Rho.Stdlib.Tools.EndTurn.tool_def()]

  @impl Rho.Transformer
  def transform(:post_step, _data, %{depth: depth}) when depth > 0, do: {:cont, nil}

  def transform(:post_step, data, _context) do
    step = Map.get(data, :step, 0)
    max_steps = Map.get(data, :max_steps, 0)

    {:inject,
     ["Step #{step} of #{max_steps}. If the task is complete, call `end_turn` to finish."]}
  end

  def transform(_stage, data, _context), do: {:cont, data}
end
