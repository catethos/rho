defmodule Rho.Tools.FsEditTest do
  use ExUnit.Case, async: true

  alias Rho.Tools.FsEdit

  @workspace "/tmp/rho_test_fs_edit"

  setup do
    File.mkdir_p!(@workspace)
    content = "line 0\nline 1\nline 2\nline 3\nline 4"
    File.write!(Path.join(@workspace, "edit.txt"), content)
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  test "replaces first occurrence" do
    [tool] = FsEdit.tools([], %{workspace: @workspace})

    assert {:ok, _} =
             tool.execute.(%{"path" => "edit.txt", "old" => "line 2", "new" => "LINE TWO"})

    content = File.read!(Path.join(@workspace, "edit.txt"))
    assert content =~ "LINE TWO"
    refute content =~ "line 2"
  end

  test "replaces only first occurrence when text appears multiple times" do
    File.write!(Path.join(@workspace, "dup.txt"), "foo\nfoo\nfoo")
    [tool] = FsEdit.tools([], %{workspace: @workspace})
    assert {:ok, _} = tool.execute.(%{"path" => "dup.txt", "old" => "foo", "new" => "bar"})
    content = File.read!(Path.join(@workspace, "dup.txt"))
    assert content == "bar\nfoo\nfoo"
  end

  test "uses start offset" do
    [tool] = FsEdit.tools([], %{workspace: @workspace})

    assert {:ok, _} =
             tool.execute.(%{
               "path" => "edit.txt",
               "old" => "line",
               "new" => "LINE",
               "start" => 3
             })

    content = File.read!(Path.join(@workspace, "edit.txt"))
    # Lines 0-2 unchanged, first "line" after line 3 is replaced
    assert content =~ "line 0"
    assert content =~ "LINE 3"
  end

  test "returns error when text not found" do
    [tool] = FsEdit.tools([], %{workspace: @workspace})

    assert {:error, msg} =
             tool.execute.(%{"path" => "edit.txt", "old" => "nonexistent", "new" => "x"})

    assert msg =~ "Text not found"
  end

  test "returns error for path escape" do
    [tool] = FsEdit.tools([], %{workspace: @workspace})
    assert {:error, msg} = tool.execute.(%{"path" => "../../bad.txt", "old" => "x", "new" => "y"})
    assert msg =~ "Path escapes workspace"
  end
end
