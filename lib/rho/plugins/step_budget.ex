defmodule Rho.Plugins.StepBudget do
  @moduledoc """
  Plugin that prevents runaway agent loops by:

  1. Injecting an `end_turn` tool that signals the loop to stop
  2. Injecting a step-budget reminder after each tool execution step,
     nudging the model to call `end_turn` when the task is done

  Only applies to top-level agents (depth 0). Subagents use `finish` instead.
  """

  @behaviour Rho.Mount

  @impl Rho.Mount
  def tools(_mount_opts, %{depth: depth}) when depth > 0, do: []
  def tools(_mount_opts, _context), do: [Rho.Tools.EndTurn.tool_def()]

  @impl Rho.Mount
  def after_step(_step, _max_steps, _mount_opts, %{depth: depth}) when depth > 0, do: :ok

  def after_step(step, max_steps, _mount_opts, _context) do
    {:inject, "Step #{step} of #{max_steps}. If the task is complete, call `end_turn` to finish."}
  end
end
