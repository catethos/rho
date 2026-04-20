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

  # --- parse_and_dispatch/3 ---

  describe "parse_and_dispatch/3 — new flat format" do
    test "dispatches respond variant" do
      text = ~s({"tool": "respond", "message": "Hello!"})

      assert {:respond, "Hello!", _opts} =
               ActionSchema.parse_and_dispatch(text, schema(), tool_map())
    end

    test "dispatches think variant" do
      text = ~s({"tool": "think", "thought": "Let me reconsider..."})

      assert {:think, "Let me reconsider..."} =
               ActionSchema.parse_and_dispatch(text, schema(), tool_map())
    end

    test "dispatches tool variant with coerced args" do
      text = ~s({"tool": "bash", "cmd": "ls -la"})

      assert {:tool, "bash", args, _td, opts} =
               ActionSchema.parse_and_dispatch(text, schema(), tool_map())

      assert args[:cmd] == "ls -la"
      assert opts[:thinking] == nil
    end

    test "dispatches tool with thinking side-channel" do
      text = ~s({"tool": "bash", "cmd": "ls", "thinking": "Check directory"})

      assert {:tool, "bash", args, _td, opts} =
               ActionSchema.parse_and_dispatch(text, schema(), tool_map())

      assert args[:cmd] == "ls"
      assert opts[:thinking] == "Check directory"
    end

    test "coerces integer args from string" do
      text = ~s({"tool": "fs_read", "path": "/tmp/f", "offset": "10"})

      assert {:tool, "fs_read", args, _td, opts} =
               ActionSchema.parse_and_dispatch(text, schema(), tool_map())

      assert args[:path] == "/tmp/f"
      assert args[:offset] == 10
      assert opts[:repairs] != []
    end

    test "returns unknown for unregistered tool" do
      text = ~s({"tool": "nonexistent", "foo": "bar"})

      assert {:unknown, "nonexistent", _args} =
               ActionSchema.parse_and_dispatch(text, schema(), tool_map())
    end

    test "returns parse_error for missing tool tag" do
      text = ~s({"cmd": "ls"})

      assert {:parse_error, :missing_tool_tag} =
               ActionSchema.parse_and_dispatch(text, schema(), tool_map())
    end

    test "returns parse_error for non-string tool tag" do
      text = ~s({"tool": 42})

      assert {:parse_error, :tool_tag_not_string} =
               ActionSchema.parse_and_dispatch(text, schema(), tool_map())
    end

    test "returns parse_error for invalid JSON" do
      text = "this is not json at all"
      assert {:parse_error, _reason} = ActionSchema.parse_and_dispatch(text, schema(), tool_map())
    end

    test "returns parse_error for non-object JSON" do
      text = ~s(["an", "array"])

      assert {:parse_error, :not_an_object} =
               ActionSchema.parse_and_dispatch(text, schema(), tool_map())
    end
  end

  describe "parse_and_dispatch/3 — edge cases" do
    test "tool in schema but not in tool_map returns unknown" do
      # Build schema with bash, but empty tool_map
      s = schema()

      assert {:unknown, "bash", _} =
               ActionSchema.parse_and_dispatch(~s({"tool": "bash", "cmd": "ls"}), s, %{})
    end

    test "respond with coercion (message as number)" do
      text = ~s({"tool": "respond", "message": 42})
      assert {:respond, "42", _opts} = ActionSchema.parse_and_dispatch(text, schema(), tool_map())
    end

    test "handles JSON wrapped in markdown fences" do
      text = "```json\n{\"tool\": \"respond\", \"message\": \"hi\"}\n```"
      assert {:respond, "hi", _opts} = ActionSchema.parse_and_dispatch(text, schema(), tool_map())
    end
  end

  # --- render_prompt/1 ---

  describe "render_prompt/1" do
    test "renders all variants" do
      output = ActionSchema.render_prompt(schema())
      assert output =~ "ActionName ="
      assert output =~ "respond(message: string)"
      assert output =~ "think(thought: string)"
      assert output =~ "bash(cmd: string)"
      assert output =~ "fs_read(path: string, offset?: integer)"
      assert output =~ "thinking?: string"
    end

    test "builtins appear before tool variants" do
      output = ActionSchema.render_prompt(schema())
      respond_pos = :binary.match(output, "respond") |> elem(0)
      think_pos = :binary.match(output, "think(") |> elem(0)
      bash_pos = :binary.match(output, "bash") |> elem(0)
      assert respond_pos < bash_pos
      assert think_pos < bash_pos
    end

    test "renders empty tool set (builtins only)" do
      s = ActionSchema.build([])
      output = ActionSchema.render_prompt(s)
      assert output =~ "respond"
      assert output =~ "think"
      refute output =~ "bash"
    end
  end
end
