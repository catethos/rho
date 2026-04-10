defmodule Rho.Stdlib.Tools.ToolSnapshotTest do
  use ExUnit.Case, async: true

  # Plugin-style modules (tools/2 returning a list of tool defs)

  describe "Bash tool name stability (snapshot)" do
    setup do
      [tool_defs: Rho.Stdlib.Tools.Bash.tools(%{}, %{workspace: "/tmp"})]
    end

    test "tool names match expected set", %{tool_defs: tool_defs} do
      names = Enum.map(tool_defs, & &1.tool.name) |> Enum.sort()
      assert names == ["bash"]
    end

    test "all tools have descriptions", %{tool_defs: tool_defs} do
      for tool_def <- tool_defs do
        assert is_binary(tool_def.tool.description)
        assert String.length(tool_def.tool.description) > 0
      end
    end

    test "all tools have 2-arity execute functions", %{tool_defs: tool_defs} do
      for tool_def <- tool_defs do
        assert is_function(tool_def.execute, 2)
      end
    end
  end

  describe "WebFetch tool name stability (snapshot)" do
    setup do
      [tool_defs: Rho.Stdlib.Tools.WebFetch.tools(%{}, %{})]
    end

    test "tool names match expected set", %{tool_defs: tool_defs} do
      names = Enum.map(tool_defs, & &1.tool.name) |> Enum.sort()
      assert names == ["web_fetch"]
    end

    test "all tools have descriptions", %{tool_defs: tool_defs} do
      for tool_def <- tool_defs do
        assert is_binary(tool_def.tool.description)
        assert String.length(tool_def.tool.description) > 0
      end
    end

    test "all tools have 2-arity execute functions", %{tool_defs: tool_defs} do
      for tool_def <- tool_defs do
        assert is_function(tool_def.execute, 2)
      end
    end
  end

  describe "FsRead tool name stability (snapshot)" do
    setup do
      [tool_defs: Rho.Stdlib.Tools.FsRead.tools(%{}, %{workspace: "/tmp"})]
    end

    test "tool names match expected set", %{tool_defs: tool_defs} do
      names = Enum.map(tool_defs, & &1.tool.name) |> Enum.sort()
      assert names == ["fs_read"]
    end

    test "all tools have descriptions", %{tool_defs: tool_defs} do
      for tool_def <- tool_defs do
        assert is_binary(tool_def.tool.description)
        assert String.length(tool_def.tool.description) > 0
      end
    end

    test "all tools have 2-arity execute functions", %{tool_defs: tool_defs} do
      for tool_def <- tool_defs do
        assert is_function(tool_def.execute, 2)
      end
    end
  end

  describe "FsWrite tool name stability (snapshot)" do
    setup do
      [tool_defs: Rho.Stdlib.Tools.FsWrite.tools(%{}, %{workspace: "/tmp"})]
    end

    test "tool names match expected set", %{tool_defs: tool_defs} do
      names = Enum.map(tool_defs, & &1.tool.name) |> Enum.sort()
      assert names == ["fs_write"]
    end

    test "all tools have descriptions", %{tool_defs: tool_defs} do
      for tool_def <- tool_defs do
        assert is_binary(tool_def.tool.description)
        assert String.length(tool_def.tool.description) > 0
      end
    end

    test "all tools have 2-arity execute functions", %{tool_defs: tool_defs} do
      for tool_def <- tool_defs do
        assert is_function(tool_def.execute, 2)
      end
    end
  end

  describe "FsEdit tool name stability (snapshot)" do
    setup do
      [tool_defs: Rho.Stdlib.Tools.FsEdit.tools(%{}, %{workspace: "/tmp"})]
    end

    test "tool names match expected set", %{tool_defs: tool_defs} do
      names = Enum.map(tool_defs, & &1.tool.name) |> Enum.sort()
      assert names == ["fs_edit"]
    end

    test "all tools have descriptions", %{tool_defs: tool_defs} do
      for tool_def <- tool_defs do
        assert is_binary(tool_def.tool.description)
        assert String.length(tool_def.tool.description) > 0
      end
    end

    test "all tools have 2-arity execute functions", %{tool_defs: tool_defs} do
      for tool_def <- tool_defs do
        assert is_function(tool_def.execute, 2)
      end
    end
  end

  # Single tool_def/0 modules

  describe "Finish tool name stability (snapshot)" do
    setup do
      [tool_def: Rho.Stdlib.Tools.Finish.tool_def()]
    end

    test "tool name matches expected", %{tool_def: tool_def} do
      assert tool_def.tool.name == "finish"
    end

    test "tool has description", %{tool_def: tool_def} do
      assert is_binary(tool_def.tool.description)
      assert String.length(tool_def.tool.description) > 0
    end

    test "tool has 2-arity execute function", %{tool_def: tool_def} do
      assert is_function(tool_def.execute, 2)
    end
  end

  describe "EndTurn tool name stability (snapshot)" do
    setup do
      [tool_def: Rho.Stdlib.Tools.EndTurn.tool_def()]
    end

    test "tool name matches expected", %{tool_def: tool_def} do
      assert tool_def.tool.name == "end_turn"
    end

    test "tool has description", %{tool_def: tool_def} do
      assert is_binary(tool_def.tool.description)
      assert String.length(tool_def.tool.description) > 0
    end

    test "tool has 2-arity execute function", %{tool_def: tool_def} do
      assert is_function(tool_def.execute, 2)
    end
  end

  # Single tool_def/1 modules (require tape_name)

  describe "ClearMemory tool name stability (snapshot)" do
    setup do
      [tool_def: Rho.Stdlib.Tools.ClearMemory.tool_def("test_tape")]
    end

    test "tool name matches expected", %{tool_def: tool_def} do
      assert tool_def.tool.name == "clear_memory"
    end

    test "tool has description", %{tool_def: tool_def} do
      assert is_binary(tool_def.tool.description)
      assert String.length(tool_def.tool.description) > 0
    end

    test "tool has 2-arity execute function", %{tool_def: tool_def} do
      assert is_function(tool_def.execute, 2)
    end
  end

  describe "SearchHistory tool name stability (snapshot)" do
    setup do
      [tool_def: Rho.Stdlib.Tools.SearchHistory.tool_def("test_tape")]
    end

    test "tool name matches expected", %{tool_def: tool_def} do
      assert tool_def.tool.name == "search_history"
    end

    test "tool has description", %{tool_def: tool_def} do
      assert is_binary(tool_def.tool.description)
      assert String.length(tool_def.tool.description) > 0
    end

    test "tool has 2-arity execute function", %{tool_def: tool_def} do
      assert is_function(tool_def.execute, 2)
    end
  end

  describe "RecallContext tool name stability (snapshot)" do
    setup do
      [tool_def: Rho.Stdlib.Tools.RecallContext.tool_def("test_tape")]
    end

    test "tool name matches expected", %{tool_def: tool_def} do
      assert tool_def.tool.name == "recall_context"
    end

    test "tool has description", %{tool_def: tool_def} do
      assert is_binary(tool_def.tool.description)
      assert String.length(tool_def.tool.description) > 0
    end

    test "tool has 2-arity execute function", %{tool_def: tool_def} do
      assert is_function(tool_def.execute, 2)
    end
  end
end
