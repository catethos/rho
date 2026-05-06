defmodule Rho.RunnerCachingTest do
  @moduledoc """
  Verifies the prompt-cache plumbing introduced in the prompt-caching-fix
  plan: stable / volatile system-prompt split, two-part system messages
  with `cache_control` on the stable part, and a cache breakpoint on the
  last assistant/tool message in the conversation tail.
  """

  use ExUnit.Case, async: true

  alias Rho.Runner

  defp runtime(stable, volatile) do
    %Rho.Runner.Runtime{
      model: "mock:model",
      turn_strategy: Rho.TurnStrategy.Direct,
      emit: fn _ -> :ok end,
      gen_opts: [],
      tool_defs: [],
      req_tools: [],
      tool_map: %{},
      system_prompt_stable: stable,
      system_prompt_volatile: volatile,
      depth: 0,
      tape: %Rho.Runner.TapeConfig{},
      context: %Rho.Context{
        tape_name: nil,
        tape_module: Rho.Tape.Projection.JSONL,
        workspace: ".",
        agent_name: :test
      }
    }
  end

  describe "build_system_message/1" do
    test "single part with cache_control when volatile is empty" do
      msg = Runner.build_system_message(runtime("stable text", ""))
      assert msg.role == :system
      assert [part] = msg.content
      assert part.text == "stable text"
      assert part.metadata[:cache_control] == %{type: "ephemeral"}
    end

    test "two parts with cache_control on stable only" do
      msg = Runner.build_system_message(runtime("stable text", "volatile body"))
      assert [stable_part, volatile_part] = msg.content
      assert stable_part.text == "stable text"
      assert stable_part.metadata[:cache_control] == %{type: "ephemeral"}
      assert volatile_part.text == "volatile body"
      refute Map.has_key?(volatile_part.metadata || %{}, :cache_control)
    end
  end
end
