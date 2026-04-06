defmodule Rho.Stdlib.Tools.FsReadTest do
  use ExUnit.Case, async: true

  alias Rho.Stdlib.Tools.FsRead

  @workspace "/tmp/rho_test_fs_read"

  setup do
    File.mkdir_p!(@workspace)
    # Create a test file with numbered lines
    content = Enum.map_join(0..9, "\n", &"line #{&1}")
    File.write!(Path.join(@workspace, "test.txt"), content)
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  test "reads entire file" do
    [tool] = FsRead.tools([], %{workspace: @workspace})
    assert {:ok, content} = tool.execute.(%{"path" => "test.txt"})
    assert content =~ "line 0"
    assert content =~ "line 9"
  end

  test "reads with offset" do
    [tool] = FsRead.tools([], %{workspace: @workspace})
    assert {:ok, content} = tool.execute.(%{"path" => "test.txt", "offset" => 5})
    refute content =~ "line 4"
    assert content =~ "line 5"
    assert content =~ "line 9"
  end

  test "reads with limit" do
    [tool] = FsRead.tools([], %{workspace: @workspace})
    assert {:ok, content} = tool.execute.(%{"path" => "test.txt", "offset" => 0, "limit" => 3})
    assert content =~ "line 0"
    assert content =~ "line 2"
    refute content =~ "line 3"
  end

  test "returns error for missing file" do
    [tool] = FsRead.tools([], %{workspace: @workspace})
    assert {:error, msg} = tool.execute.(%{"path" => "nonexistent.txt"})
    assert msg =~ "Cannot read"
  end

  test "returns error for path escape" do
    [tool] = FsRead.tools([], %{workspace: @workspace})
    assert {:error, msg} = tool.execute.(%{"path" => "../../../etc/passwd"})
    assert msg =~ "Path escapes workspace"
  end

  test "components returns valid tool structure" do
    [tool] = FsRead.tools([], %{workspace: @workspace})
    assert tool.tool.name == "fs_read"
    assert is_function(tool.execute, 1)
  end
end
