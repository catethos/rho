defmodule Rho.ActionSchemaTest do
  use ExUnit.Case, async: true

  alias Rho.ActionSchema

  # --- Test helpers ---

  defp make_tool_def(name, params \\ []) do
    %{
      tool: %{
        name: name,
        description: "Test tool #{name}",
        parameter_schema: params
      },
      execute: fn args, _ctx -> {:ok, inspect(args)} end
    }
  end

  defp tool_defs do
    [
      make_tool_def("bash", cmd: [type: :string, required: true, doc: "Command to run"]),
      make_tool_def("fs_read", path: [type: :string, required: true], offset: [type: :integer])
    ]
  end

  defp schema, do: ActionSchema.build(tool_defs())

  defp tool_map do
    Map.new(tool_defs(), fn td -> {td.tool.name, td} end)
  end

  # --- build/1 ---

  describe "build/1" do
    test "creates schema with built-in and tool variants" do
      s = schema()
      assert %ActionSchema{tag_key: "tool"} = s
      assert Map.has_key?(s.variants, "respond")
      assert Map.has_key?(s.variants, "think")
      assert Map.has_key?(s.variants, "bash")
      assert Map.has_key?(s.variants, "fs_read")
      assert s.variants["respond"].builtin == true
      assert s.variants["think"].builtin == true
      assert s.variants["bash"].builtin == false
    end

    test "raises on reserved name collision — respond" do
      assert_raise ArgumentError, ~r/collides with built-in/, fn ->
        ActionSchema.build([make_tool_def("respond")])
      end
    end

    test "raises on reserved name collision — think" do
      assert_raise ArgumentError, ~r/collides with built-in/, fn ->
        ActionSchema.build([make_tool_def("think")])
      end
    end

    test "raises on duplicate tool names" do
      assert_raise ArgumentError, ~r/Duplicate tool names/, fn ->
        ActionSchema.build([
          make_tool_def("bash"),
          make_tool_def("bash")
        ])
      end
    end

    test "builds with empty tool_defs (builtins only)" do
      s = ActionSchema.build([])
      assert map_size(s.variants) == 2
      assert Map.has_key?(s.variants, "respond")
      assert Map.has_key?(s.variants, "think")
    end

    test "preserves parameter_schema as variant fields" do
      s = schema()

      assert s.variants["bash"].fields == [
               cmd: [type: :string, required: true, doc: "Command to run"]
             ]

      assert s.variants["fs_read"].fields == [
               path: [type: :string, required: true],
               offset: [type: :integer]
             ]
    end
  end

  # --- dispatch_parsed/3 ---

  describe "deferred tools" do
    test "tool not in schema but in tool_map dispatches successfully" do
      # Build schema with only fs_read — bash is "deferred" (not in schema)
      visible_defs = [
        make_tool_def("fs_read", path: [type: :string, required: true])
      ]

      schema = ActionSchema.build(visible_defs)
      refute Map.has_key?(schema.variants, "bash")

      # But bash IS in tool_map (deferred = callable but not in prompt)
      full_map = tool_map()
      assert Map.has_key?(full_map, "bash")

      assert {:tool, "bash", args, _td, _opts} =
               ActionSchema.dispatch_parsed(
                 %{"tool" => "bash", "cmd" => "ls -la"},
                 schema,
                 full_map
               )

      assert args[:cmd] == "ls -la"
    end

    test "tool not in schema and not in tool_map returns unknown" do
      schema = ActionSchema.build([])

      assert {:unknown, "nonexistent", _args} =
               ActionSchema.dispatch_parsed(
                 %{"tool" => "nonexistent", "foo" => "bar"},
                 schema,
                 %{}
               )
    end
  end
end
