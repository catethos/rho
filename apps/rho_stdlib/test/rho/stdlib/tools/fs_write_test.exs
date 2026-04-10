defmodule Rho.Stdlib.Tools.FsWriteTest do
  use ExUnit.Case, async: true

  alias Rho.Stdlib.Tools.FsWrite

  @workspace "/tmp/rho_test_fs_write"

  setup do
    File.mkdir_p!(@workspace)
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  test "writes a new file" do
    [tool] = FsWrite.tools([], %{workspace: @workspace})
    assert {:ok, msg} = tool.execute.(%{path: "hello.txt", content: "hello world"}, %{})
    assert msg =~ "11 bytes"
    assert File.read!(Path.join(@workspace, "hello.txt")) == "hello world"
  end

  test "creates parent directories" do
    [tool] = FsWrite.tools([], %{workspace: @workspace})
    assert {:ok, _} = tool.execute.(%{path: "sub/deep/file.txt", content: "nested"}, %{})
    assert File.read!(Path.join(@workspace, "sub/deep/file.txt")) == "nested"
  end

  test "overwrites existing file" do
    path = Path.join(@workspace, "overwrite.txt")
    File.write!(path, "old content")
    [tool] = FsWrite.tools([], %{workspace: @workspace})
    assert {:ok, _} = tool.execute.(%{path: "overwrite.txt", content: "new content"}, %{})
    assert File.read!(path) == "new content"
  end

  test "returns error for path escape" do
    [tool] = FsWrite.tools([], %{workspace: @workspace})
    assert {:error, msg} = tool.execute.(%{path: "../../escape.txt", content: "bad"}, %{})
    assert msg =~ "Path escapes workspace"
  end
end
