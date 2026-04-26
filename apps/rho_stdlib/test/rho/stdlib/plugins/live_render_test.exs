defmodule Rho.Stdlib.Plugins.LiveRenderTest do
  use ExUnit.Case, async: true

  alias Rho.Stdlib.Plugins.LiveRender

  @valid_spec %{
    "root" => "main",
    "elements" => %{
      "main" => %{"type" => "stack", "props" => %{}, "children" => ["c1"]},
      "c1" => %{"type" => "card", "props" => %{"title" => "Test"}, "children" => []}
    }
  }

  describe "tools/2" do
    test "returns present_ui tool at depth 0" do
      context = %{depth: 0, session_id: "s1", agent_id: "a1"}
      tools = LiveRender.tools([], context)
      assert length(tools) == 1
      assert %{tool: tool, execute: execute} = hd(tools)
      assert tool.name == "present_ui"
      assert is_function(execute, 2)
    end

    test "returns no tools at depth > 0" do
      context = %{depth: 1, session_id: "s1", agent_id: "a1"}
      assert LiveRender.tools([], context) == []
    end
  end

  describe "prompt_sections/2" do
    test "returns a PromptSection struct" do
      sections = LiveRender.prompt_sections([], %{})
      assert length(sections) == 1
      section = hd(sections)
      assert %Rho.PromptSection{key: :live_render} = section
      assert section.heading =~ "present_ui"
      assert section.body =~ "Components:"
      assert length(section.examples) == 1
    end

    test "returns empty at depth > 0" do
      assert [] = LiveRender.prompt_sections([], %{depth: 1})
    end
  end

  describe "execute present_ui" do
    test "validates missing spec" do
      context = %{depth: 0, session_id: "s1", agent_id: "a1"}
      [%{execute: execute}] = LiveRender.tools([], context)
      assert {:error, "spec parameter is required"} = execute.(%{}, %{})
    end

    test "validates missing root" do
      context = %{depth: 0, session_id: "s1", agent_id: "a1"}
      [%{execute: execute}] = LiveRender.tools([], context)

      bad_spec = %{"elements" => %{}}
      assert {:error, "spec must contain a 'root' key"} = execute.(%{spec: bad_spec}, %{})
    end

    test "validates missing elements" do
      context = %{depth: 0, session_id: "s1", agent_id: "a1"}
      [%{execute: execute}] = LiveRender.tools([], context)

      bad_spec = %{"root" => "main"}

      assert {:error, "spec must contain an 'elements' map"} =
               execute.(%{spec: bad_spec}, %{})
    end

    test "validates unknown component types" do
      context = %{depth: 0, session_id: "s1", agent_id: "a1"}
      [%{execute: execute}] = LiveRender.tools([], context)

      bad_spec = %{
        "root" => "main",
        "elements" => %{
          "main" => %{"type" => "nonexistent_widget", "props" => %{}, "children" => []}
        }
      }

      assert {:error, msg} = execute.(%{spec: bad_spec}, %{})
      assert msg =~ "unknown component types: nonexistent_widget"
    end

    test "validates spec size" do
      context = %{depth: 0, session_id: "s1", agent_id: "a1"}
      [%{execute: execute}] = LiveRender.tools([max_spec_bytes: 10], context)
      assert {:error, msg} = execute.(%{spec: @valid_spec}, %{})
      assert msg =~ "exceeds maximum size"
    end

    test "accepts valid spec without session (no signal emitted)" do
      context = %{depth: 0, session_id: nil, agent_id: "a1"}
      [%{execute: execute}] = LiveRender.tools([], context)
      assert {:ok, "Rendered."} = execute.(%{spec: @valid_spec}, %{})
    end
  end
end
