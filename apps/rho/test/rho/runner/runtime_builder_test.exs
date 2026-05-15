defmodule Rho.Runner.RuntimeBuilderTest do
  use ExUnit.Case, async: true

  alias Rho.Runner.{Runtime, RuntimeBuilder, TapeConfig}

  defmodule StrategyWithSections do
    def prompt_sections(_tools, _ctx) do
      [
        Rho.PromptSection.new(
          key: :stable_strategy,
          body: "Stable strategy guidance.",
          priority: :normal,
          kind: :instructions
        ),
        %Rho.PromptSection{
          key: :volatile_strategy,
          body: "Volatile strategy state.",
          priority: :normal,
          kind: :context,
          volatile: true
        }
      ]
    end
  end

  describe "from_spec/1" do
    test "builds runtime context, tape, provider opts, and prompt sections" do
      spec =
        Rho.RunSpec.build(
          model: "mock:model",
          provider: %{order: ["anthropic"]},
          system_prompt: "Base prompt.",
          turn_strategy: StrategyWithSections,
          tape_name: "builder_tape",
          compact_threshold: 123,
          session_id: "sid",
          agent_id: "agent",
          conversation_id: "conv",
          thread_id: "thread",
          turn_id: "turn",
          workspace: "workspace",
          agent_name: :coder,
          depth: 2,
          lite: true
        )

      assert %Runtime{} = runtime = RuntimeBuilder.from_spec(spec)
      assert runtime.model == "mock:model"
      assert runtime.turn_strategy == StrategyWithSections
      assert runtime.depth == 2
      assert runtime.lite == true

      assert runtime.gen_opts == [
               provider_options: [openrouter_provider: %{order: ["anthropic"]}]
             ]

      assert %TapeConfig{name: "builder_tape", compact_threshold: 123} = runtime.tape
      assert runtime.context.session_id == "sid"
      assert runtime.context.agent_id == "agent"
      assert runtime.context.conversation_id == "conv"
      assert runtime.context.thread_id == "thread"
      assert runtime.context.turn_id == "turn"
      assert runtime.context.workspace == "workspace"
      assert runtime.context.agent_name == :coder

      assert runtime.system_prompt_stable =~ "Base prompt."
      assert runtime.system_prompt_stable =~ "Stable strategy guidance."
      assert runtime.system_prompt_stable =~ "Be concise between tool calls."
      assert runtime.system_prompt_volatile =~ "Volatile strategy state."
    end
  end

  describe "from_legacy/2" do
    test "preserves legacy callback resolution and defaults" do
      parent = self()

      runtime =
        RuntimeBuilder.from_legacy("mock:legacy",
          on_text: fn chunk -> send(parent, {:chunk, chunk}) end,
          on_event: fn event -> send(parent, {:event, event}) end
        )

      assert runtime.model == "mock:legacy"
      assert runtime.turn_strategy == Rho.TurnStrategy.Direct
      assert runtime.tape.name == nil
      assert runtime.context.prompt_format == :markdown

      assert :ok = runtime.emit.(%{type: :text_delta, text: "hi"})
      assert_receive {:chunk, "hi"}

      runtime.emit.(%{type: :step_start, step: 1})
      assert_receive {:event, %{type: :step_start, step: 1}}
    end
  end
end
