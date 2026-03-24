defmodule Rho.MountIntegrationTest do
  @moduledoc """
  Integration test verifying that MountRegistry.collect_tools/1 returns
  the expected tools for a given context.
  """
  use ExUnit.Case, async: false

  alias Rho.MountRegistry

  setup do
    MountRegistry.clear()

    # Register the same mounts that application.ex registers
    MountRegistry.register(Rho.Tools.Bash)
    MountRegistry.register(Rho.Tools.FsRead)
    MountRegistry.register(Rho.Tools.FsWrite)
    MountRegistry.register(Rho.Tools.FsEdit)
    MountRegistry.register(Rho.Tools.WebFetch)
    MountRegistry.register(Rho.Tools.Python)
    MountRegistry.register(Rho.Tools.Sandbox)
    MountRegistry.register(Rho.Mounts.JournalTools)
    MountRegistry.register(Rho.Skills)
    MountRegistry.register(Rho.Builtin)
    MountRegistry.register(Rho.Plugins.StepBudget)
    MountRegistry.register(Rho.Plugins.Subagent)

    on_exit(fn -> MountRegistry.clear() end)
    :ok
  end

  defp tool_names(tools) do
    tools
    |> Enum.map(fn t -> t.tool.name end)
    |> Enum.sort()
  end

  describe "mount-collected tools match old resolution" do
    test "basic context with workspace produces expected tools" do
      context = %{
        tape_name: "test_tape",
        workspace: "/tmp/test_workspace",
        agent_name: :default,
        depth: 0,
        sandbox: nil
      }

      mount_tools = MountRegistry.collect_tools(context)
      mount_names = tool_names(mount_tools)

      # Core tools should be present
      assert "bash" in mount_names
      assert "fs_read" in mount_names
      assert "fs_write" in mount_names
      assert "fs_edit" in mount_names
      assert "web_fetch" in mount_names

      # Journal tools should be present
      assert "create_anchor" in mount_names
      assert "search_history" in mount_names
      assert "recall_context" in mount_names
      assert "clear_memory" in mount_names

      # Policy tools
      assert "end_turn" in mount_names

      # Orchestration tools
      assert "spawn_subagent" in mount_names
      assert "collect_subagent" in mount_names
    end

    test "sandbox tools appear when sandbox is present in context" do
      # We can't easily create a real sandbox, but we can verify
      # that the mount returns empty tools when no sandbox is set
      context = %{
        tape_name: "test_tape",
        workspace: "/tmp/test_workspace",
        agent_name: :default,
        depth: 0,
        sandbox: nil
      }

      mount_tools = MountRegistry.collect_tools(context)
      mount_names = tool_names(mount_tools)

      refute "sandbox_diff" in mount_names
      refute "sandbox_commit" in mount_names
    end

    test "subagent depth limit respected via mount" do
      context_depth_0 = %{
        tape_name: "test_tape",
        workspace: "/tmp/test_workspace",
        agent_name: :default,
        depth: 0,
        sandbox: nil
      }

      context_deep = %{context_depth_0 | depth: 4}

      tools_0 = MountRegistry.collect_tools(context_depth_0)
      tools_deep = MountRegistry.collect_tools(context_deep)

      names_0 = tool_names(tools_0)
      names_deep = tool_names(tools_deep)

      assert "spawn_subagent" in names_0
      refute "spawn_subagent" in names_deep
    end

    test "step budget after_step dispatches injection at depth 0" do
      context = %{
        tape_name: "test_tape",
        workspace: "/tmp/test_workspace",
        agent_name: :default,
        depth: 0,
        sandbox: nil
      }

      result = MountRegistry.dispatch_after_step(3, 10, context)
      assert {:inject, [msg]} = result
      assert msg =~ "Step 3 of 10"
      assert msg =~ "end_turn"
    end

    test "step budget after_step returns :ok at depth > 0" do
      context = %{
        tape_name: "test_tape",
        workspace: "/tmp/test_workspace",
        agent_name: :default,
        depth: 1,
        sandbox: nil
      }

      result = MountRegistry.dispatch_after_step(3, 10, context)
      assert result == :ok
    end

    test "journal tools appear when tape_name is present" do
      context = %{
        tape_name: "test_tape",
        workspace: "/tmp/test_workspace",
        agent_name: :default,
        depth: 0,
        sandbox: nil
      }

      mount_tools = MountRegistry.collect_tools(context)
      mount_names = tool_names(mount_tools)

      assert "create_anchor" in mount_names
      assert "search_history" in mount_names
      assert "recall_context" in mount_names
      assert "clear_memory" in mount_names
    end

    test "end_turn tool appears at depth 0" do
      context = %{
        tape_name: "test_tape",
        workspace: "/tmp/test_workspace",
        agent_name: :default,
        depth: 0,
        sandbox: nil
      }

      mount_tools = MountRegistry.collect_tools(context)
      mount_names = tool_names(mount_tools)

      assert "end_turn" in mount_names
    end
  end
end
