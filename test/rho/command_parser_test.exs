defmodule Rho.CommandParserTest do
  use ExUnit.Case, async: true

  alias Rho.CommandParser

  doctest Rho.CommandParser

  describe "parse/1" do
    test "empty string defaults to bash" do
      assert {"bash", %{}} = CommandParser.parse("")
    end

    test "whitespace-only defaults to bash" do
      assert {"bash", %{}} = CommandParser.parse("   ")
    end

    test "tool name only" do
      assert {"fs_read", %{}} = CommandParser.parse("fs_read")
    end

    test "tool name with key=value args" do
      assert {"fs_read", %{"path" => "/tmp/foo.txt"}} =
               CommandParser.parse("fs_read path=/tmp/foo.txt")
    end

    test "tool name with multiple key=value args" do
      assert {"fs_edit", %{"path" => "/tmp/foo.txt", "old" => "hello", "new" => "world"}} =
               CommandParser.parse("fs_edit path=/tmp/foo.txt old=hello new=world")
    end

    test "tool name with positional args becomes cmd" do
      assert {"bash", %{"cmd" => "ls -la /tmp"}} =
               CommandParser.parse("bash ls -la /tmp")
    end

    test "mixed key=value and positional args" do
      result = CommandParser.parse("bash path=/tmp echo hello")
      assert result == {"bash", %{"path" => "/tmp", "cmd" => "echo hello"}}
    end

    test "value containing equals sign" do
      assert {"web_fetch", %{"url" => "https://example.com?a=1"}} =
               CommandParser.parse("web_fetch url=https://example.com?a=1")
    end
  end

  describe "parse_args/1" do
    test "empty string" do
      assert %{} = CommandParser.parse_args("")
    end

    test "single key=value" do
      assert %{"path" => "/foo"} = CommandParser.parse_args("path=/foo")
    end

    test "positional only" do
      assert %{"cmd" => "hello world"} = CommandParser.parse_args("hello world")
    end
  end
end
