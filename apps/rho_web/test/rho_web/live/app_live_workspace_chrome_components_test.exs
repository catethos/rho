defmodule RhoWeb.AppLiveWorkspaceChromeComponentsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.AppLive.WorkspaceChromeComponents

  test "debug_command prefers conversation ids over session ids" do
    assert WorkspaceChromeComponents.debug_command(%{"id" => "conv-1"}, "sid-1") ==
             "mix rho.debug conv-1"

    assert WorkspaceChromeComponents.debug_command(nil, "sid-1") == "mix rho.debug sid-1"
    assert WorkspaceChromeComponents.debug_command(nil, nil) == "mix rho.debug <ref>"
  end

  test "debug_content_string preserves strings and inspects structured content" do
    assert WorkspaceChromeComponents.debug_content_string("hello") == "hello"

    assert WorkspaceChromeComponents.debug_content_string(%{tool: "search"}) ==
             "%{tool: \"search\"}"
  end
end
