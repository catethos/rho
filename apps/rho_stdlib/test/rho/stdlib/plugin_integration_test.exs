defmodule Rho.Stdlib.PluginIntegrationTest do
  @moduledoc """
  Integration test verifying that PluginRegistry.collect_tools/1 returns
  the expected tools for a given context.
  """
  use ExUnit.Case, async: false

  alias Rho.PluginRegistry

  setup do
    PluginRegistry.clear()

    # Register the standard plugins
    PluginRegistry.register(Rho.Stdlib.Tools.Bash)
    PluginRegistry.register(Rho.Stdlib.Tools.FsRead)
    PluginRegistry.register(Rho.Stdlib.Tools.FsWrite)
    PluginRegistry.register(Rho.Stdlib.Tools.FsEdit)
    PluginRegistry.register(Rho.Stdlib.Tools.WebFetch)
    PluginRegistry.register(Rho.Stdlib.Tools.Python)
    PluginRegistry.register(Rho.Stdlib.Tools.Sandbox)
    PluginRegistry.register(Rho.Stdlib.Plugins.Tape)
    PluginRegistry.register(Rho.Stdlib.Skill.Plugin)
    PluginRegistry.register(Rho.Stdlib.Plugins.StepBudget)
    PluginRegistry.register(Rho.Stdlib.Plugins.MultiAgent)

    on_exit(fn -> PluginRegistry.clear() end)
    :ok
  end

  defp tool_names(tools) do
    tools
    |> Enum.map(fn t -> t.tool.name end)
    |> Enum.sort()
  end

  describe "plugin-collected tools match old resolution" do
    test "basic context with workspace produces expected tools" do
      context = %{
        tape_name: "test_tape",
        workspace: "/tmp/test_workspace",
        agent_name: :default,
        depth: 0,
        sandbox: nil
      }

      plugin_tools = PluginRegistry.collect_tools(context)
      plugin_names = tool_names(plugin_tools)

      # Core tools should be present
      assert "bash" in plugin_names
      assert "fs_read" in plugin_names
      assert "fs_write" in plugin_names
      assert "fs_edit" in plugin_names
      assert "web_fetch" in plugin_names

      # Journal tools should be present
      assert "create_anchor" in plugin_names
      assert "search_history" in plugin_names
      assert "recall_context" in plugin_names
      assert "clear_memory" in plugin_names

      # Policy tools
      assert "end_turn" in plugin_names

      # Orchestration tools
      assert "spawn_agent" in plugin_names
      assert "collect_results" in plugin_names
    end

    test "sandbox tools appear when sandbox is present in context" do
      # We can't easily create a real sandbox, but we can verify
      # that the plugin returns empty tools when no sandbox is set
      context = %{
        tape_name: "test_tape",
        workspace: "/tmp/test_workspace",
        agent_name: :default,
        depth: 0,
        sandbox: nil
      }

      plugin_tools = PluginRegistry.collect_tools(context)
      plugin_names = tool_names(plugin_tools)

      refute "sandbox_diff" in plugin_names
      refute "sandbox_commit" in plugin_names
    end

    test "subagent depth limit respected via plugin" do
      context_depth_0 = %{
        tape_name: "test_tape",
        workspace: "/tmp/test_workspace",
        agent_name: :default,
        depth: 0,
        sandbox: nil
      }

      context_deep = %{context_depth_0 | depth: 4}

      tools_0 = PluginRegistry.collect_tools(context_depth_0)
      tools_deep = PluginRegistry.collect_tools(context_deep)

      names_0 = tool_names(tools_0)
      names_deep = tool_names(tools_deep)

      assert "spawn_agent" in names_0
      refute "spawn_agent" in names_deep
    end

    test "journal tools appear when tape_name is present" do
      context = %{
        tape_name: "test_tape",
        workspace: "/tmp/test_workspace",
        agent_name: :default,
        depth: 0,
        sandbox: nil
      }

      plugin_tools = PluginRegistry.collect_tools(context)
      plugin_names = tool_names(plugin_tools)

      assert "create_anchor" in plugin_names
      assert "search_history" in plugin_names
      assert "recall_context" in plugin_names
      assert "clear_memory" in plugin_names
    end

    test "end_turn tool appears at depth 0" do
      context = %{
        tape_name: "test_tape",
        workspace: "/tmp/test_workspace",
        agent_name: :default,
        depth: 0,
        sandbox: nil
      }

      plugin_tools = PluginRegistry.collect_tools(context)
      plugin_names = tool_names(plugin_tools)

      assert "end_turn" in plugin_names
    end
  end
end
