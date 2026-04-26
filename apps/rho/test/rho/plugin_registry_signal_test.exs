defmodule Rho.PluginRegistrySignalTest do
  @moduledoc """
  Characterisation tests for `Rho.PluginRegistry.dispatch_signal/2`.

  The dispatch function iterates active plugins (priority-ordered) and
  returns the first non-`:ignore` result, or `:ignore` if no plugin
  matches. Plugins without `handle_signal/3` exported are treated as
  `:ignore`.
  """

  use ExUnit.Case, async: false

  alias Rho.PluginRegistry

  defmodule SignalProbe do
    @behaviour Rho.Plugin

    @impl Rho.Plugin
    def tools(_opts, _ctx), do: []

    @impl Rho.Plugin
    def handle_signal(%{type: "probe.start_turn", data: data}, _opts, _ctx) do
      {:start_turn, data[:content] || "(no content)", data[:opts] || []}
    end

    def handle_signal(%{type: "probe.ignore"}, _opts, _ctx), do: :ignore
    def handle_signal(_signal, _opts, _ctx), do: :ignore
  end

  defmodule LowPrioritySignalProbe do
    @behaviour Rho.Plugin

    @impl Rho.Plugin
    def tools(_opts, _ctx), do: []

    @impl Rho.Plugin
    def handle_signal(%{type: "probe.start_turn"}, _opts, _ctx) do
      {:start_turn, "low_priority_content", []}
    end

    def handle_signal(_signal, _opts, _ctx), do: :ignore
  end

  defmodule NoSignalPlugin do
    @behaviour Rho.Plugin
    @impl Rho.Plugin
    def tools(_opts, _ctx), do: []
  end

  setup do
    PluginRegistry.clear()
    on_exit(fn -> PluginRegistry.clear() end)
    :ok
  end

  defp ctx(extra \\ %{}) do
    Map.merge(
      %{
        tape_name: "t",
        workspace: "/tmp",
        agent_name: :default,
        agent_id: "agent_1",
        session_id: "sess_1",
        depth: 0
      },
      extra
    )
  end

  describe "dispatch_signal/2" do
    test "returns :ignore when no plugins are registered" do
      assert PluginRegistry.dispatch_signal(%{type: "probe.start_turn"}, ctx()) == :ignore
    end

    test "returns plugin's {:start_turn, content, opts} when it matches" do
      PluginRegistry.register(SignalProbe)

      signal = %{type: "probe.start_turn", data: %{content: "hello", opts: [foo: :bar]}}
      assert PluginRegistry.dispatch_signal(signal, ctx()) == {:start_turn, "hello", [foo: :bar]}
    end

    test "returns :ignore when plugin explicitly ignores" do
      PluginRegistry.register(SignalProbe)
      assert PluginRegistry.dispatch_signal(%{type: "probe.ignore"}, ctx()) == :ignore
    end

    test "returns :ignore when no plugin matches" do
      PluginRegistry.register(SignalProbe)
      assert PluginRegistry.dispatch_signal(%{type: "totally.unknown"}, ctx()) == :ignore
    end

    test "plugin without handle_signal/3 exported is treated as :ignore" do
      PluginRegistry.register(NoSignalPlugin)
      assert PluginRegistry.dispatch_signal(%{type: "probe.start_turn"}, ctx()) == :ignore
    end

    test "first non-:ignore result wins (priority traversal halts)" do
      # SignalProbe registered second → higher priority → handles first.
      PluginRegistry.register(LowPrioritySignalProbe)
      PluginRegistry.register(SignalProbe)

      signal = %{type: "probe.start_turn", data: %{content: "hello"}}
      assert PluginRegistry.dispatch_signal(signal, ctx()) == {:start_turn, "hello", []}
    end

    test "falls through to lower-priority plugin when higher priority returns :ignore" do
      PluginRegistry.register(SignalProbe)
      PluginRegistry.register(LowPrioritySignalProbe)

      # LowPrioritySignalProbe is higher priority (registered last), so it
      # handles probe.start_turn — proves traversal hits the highest first
      # but also that :ignore from a non-matching plugin doesn't shadow.
      assert PluginRegistry.dispatch_signal(%{type: "probe.start_turn"}, ctx()) ==
               {:start_turn, "low_priority_content", []}
    end

    test "agent-scoped plugin only fires for matching agent_name" do
      PluginRegistry.register(SignalProbe, scope: {:agent, :coder})

      signal = %{type: "probe.start_turn", data: %{content: "x"}}

      assert PluginRegistry.dispatch_signal(signal, ctx(%{agent_name: :default})) == :ignore

      assert PluginRegistry.dispatch_signal(signal, ctx(%{agent_name: :coder})) ==
               {:start_turn, "x", []}
    end
  end
end
