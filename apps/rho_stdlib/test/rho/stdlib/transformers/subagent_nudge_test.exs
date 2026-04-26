defmodule Rho.Stdlib.Transformers.SubagentNudgeTest do
  use ExUnit.Case, async: true

  alias Rho.Stdlib.Transformers.SubagentNudge

  describe "transform(:post_step, ...)" do
    test "injects nudge for text-only response at depth > 0" do
      data = %{step: 2, max_steps: 30, entries_appended: [], step_kind: :text_response}
      ctx = %{depth: 1}

      assert {:inject, [nudge]} = SubagentNudge.transform(:post_step, data, ctx)
      assert is_binary(nudge)
      assert nudge =~ "finish"
    end

    test "no-op for text-only response at depth 0" do
      data = %{step: 2, max_steps: 30, entries_appended: [], step_kind: :text_response}
      ctx = %{depth: 0}

      assert {:cont, _} = SubagentNudge.transform(:post_step, data, ctx)
    end

    test "no-op for tool step at depth > 0" do
      data = %{step: 2, max_steps: 30, entries_appended: [%{}], step_kind: :tool_step}
      ctx = %{depth: 2}

      assert {:cont, _} = SubagentNudge.transform(:post_step, data, ctx)
    end

    test "no-op for think step at depth > 0" do
      data = %{step: 2, max_steps: 30, entries_appended: [], step_kind: :think_step}
      ctx = %{depth: 1}

      assert {:cont, _} = SubagentNudge.transform(:post_step, data, ctx)
    end
  end

  describe "transform(other_stage, ...)" do
    test "passes data through for non-:post_step stages" do
      data = %{messages: [], system: nil}
      ctx = %{depth: 1}

      assert {:cont, ^data} = SubagentNudge.transform(:prompt_out, data, ctx)
    end
  end
end
