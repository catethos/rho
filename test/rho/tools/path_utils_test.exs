defmodule Rho.Tools.PathUtilsTest do
  use ExUnit.Case, async: true

  alias Rho.Tools.PathUtils

  @workspace "/tmp/rho_test_workspace"

  setup do
    File.mkdir_p!(@workspace)
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  test "resolves relative path within workspace" do
    assert PathUtils.resolve_path(@workspace, "foo.txt") ==
             Path.expand("foo.txt", @workspace)
  end

  test "resolves nested relative path" do
    assert PathUtils.resolve_path(@workspace, "sub/dir/file.ex") ==
             Path.expand("sub/dir/file.ex", @workspace)
  end

  test "resolves absolute path within workspace" do
    abs = Path.join(@workspace, "bar.txt")
    assert PathUtils.resolve_path(@workspace, abs) == abs
  end

  test "raises on path escaping workspace via .." do
    assert_raise RuntimeError, ~r/Path escapes workspace/, fn ->
      PathUtils.resolve_path(@workspace, "../../../etc/passwd")
    end
  end

  test "raises on absolute path outside workspace" do
    assert_raise RuntimeError, ~r/Path escapes workspace/, fn ->
      PathUtils.resolve_path(@workspace, "/etc/passwd")
    end
  end

  test "normalizes path with embedded .." do
    # sub/../file.txt resolves to file.txt within workspace — should be fine
    result = PathUtils.resolve_path(@workspace, "sub/../file.txt")
    assert result == Path.expand("file.txt", @workspace)
  end
end
