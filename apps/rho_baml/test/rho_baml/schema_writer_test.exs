defmodule RhoBaml.SchemaWriterTest do
  use ExUnit.Case, async: true

  alias RhoBaml.SchemaWriter

  defp tool_def(name, params, description \\ "Test tool") do
    %{
      tool: %{
        name: name,
        description: description,
        parameter_schema: params
      }
    }
  end

  describe "to_baml/2 — discriminated union shape" do
    test "emits reserved RespondAction and ThinkAction even with no tools" do
      baml = SchemaWriter.to_baml([])

      assert baml =~ ~s(class RespondAction {)
      assert baml =~ ~s(  tool "respond")
      assert baml =~ ~s(  message string\n)
      assert baml =~ ~s(  thinking string?)

      assert baml =~ ~s(class ThinkAction {)
      assert baml =~ ~s(  tool "think")
      assert baml =~ ~s(  thought string\n)

      assert baml =~ "function AgentTurn(messages: string) -> RespondAction | ThinkAction {"
    end

    test "emits one variant per tool with literal tool discriminant" do
      defs = [
        tool_def("bash", cmd: [type: :string, required: true]),
        tool_def("fs_read", path: [type: :string, required: true])
      ]

      baml = SchemaWriter.to_baml(defs)

      assert baml =~ ~s(class BashAction {)
      assert baml =~ ~s(  tool "bash")
      assert baml =~ ~s(class FsReadAction {)
      assert baml =~ ~s(  tool "fs_read")
    end

    test "function return type is union of all variants in order" do
      defs = [
        tool_def("bash", cmd: [type: :string, required: true]),
        tool_def("fs_read", path: [type: :string, required: true])
      ]

      baml = SchemaWriter.to_baml(defs)

      assert baml =~
               "function AgentTurn(messages: string) -> RespondAction | ThinkAction | BashAction | FsReadAction {"
    end
  end

  describe "to_baml/2 — required vs optional fields" do
    test "required fields are emitted without `?`" do
      defs = [tool_def("bash", cmd: [type: :string, required: true])]
      baml = SchemaWriter.to_baml(defs)

      # Field appears without `?` after the type.
      assert baml =~ ~r/class BashAction \{[^}]*  cmd string\n/
    end

    test "optional fields are emitted with `?`" do
      defs = [tool_def("fs_read", offset: [type: :integer])]
      baml = SchemaWriter.to_baml(defs)

      assert baml =~ ~r/class FsReadAction \{[^}]*  offset int\?\n/
    end

    test "required and optional preserved per-tool side-by-side" do
      defs = [
        tool_def("fs_read",
          path: [type: :string, required: true],
          offset: [type: :integer]
        )
      ]

      baml = SchemaWriter.to_baml(defs)

      assert baml =~ ~r/class FsReadAction \{[^}]*  path string\n  offset int\?/
    end
  end

  describe "to_baml/2 — class naming" do
    test "snake_case tool name → CamelCase + Action suffix" do
      defs = [tool_def("generate_framework_skeletons", name: [type: :string, required: true])]
      baml = SchemaWriter.to_baml(defs)

      assert baml =~ ~s(class GenerateFrameworkSkeletonsAction {)
      assert baml =~ ~s(  tool "generate_framework_skeletons")
    end

    test "single-word tool name → CamelCase + Action suffix" do
      defs = [tool_def("bash", cmd: [type: :string, required: true])]
      baml = SchemaWriter.to_baml(defs)

      assert baml =~ ~s(class BashAction {)
    end
  end

  describe "to_baml/2 — deferred tools" do
    test "deferred tools are excluded from variants AND union" do
      defs = [
        tool_def("bash", cmd: [type: :string, required: true]),
        Map.put(tool_def("hidden", x: [type: :string, required: true]), :deferred, true)
      ]

      baml = SchemaWriter.to_baml(defs)

      assert baml =~ ~s(class BashAction {)
      refute baml =~ ~s(class HiddenAction {)
      refute baml =~ ~s(  tool "hidden")
      refute baml =~ "HiddenAction"
    end
  end

  describe "to_baml/2 — thinking field" do
    test "every variant carries `thinking string?`" do
      defs = [
        tool_def("bash", cmd: [type: :string, required: true]),
        tool_def("fs_read", path: [type: :string, required: true])
      ]

      baml = SchemaWriter.to_baml(defs)

      # Count `thinking string?` — once per variant: respond, think, bash, fs_read = 4
      occurrences =
        baml
        |> String.split("thinking string?")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 4
    end
  end

  describe "to_baml/2 — descriptions on tool literal" do
    test "each variant carries description as @description on its tool field" do
      defs = [tool_def("bash", [cmd: [type: :string, required: true]], "Run a shell command")]
      baml = SchemaWriter.to_baml(defs)

      assert baml =~ ~s|  tool "respond" @description("Reply to the user with a final message.")|

      assert baml =~
               ~s|  tool "think" @description("Record an internal reasoning step without external action.")|

      assert baml =~ ~s|  tool "bash" @description("Run a shell command")|
    end

    test "descriptions with double-quotes are escaped" do
      defs = [
        tool_def(
          "bash",
          [cmd: [type: :string, required: true]],
          ~s|Run a "shell" command|
        )
      ]

      baml = SchemaWriter.to_baml(defs)
      assert baml =~ ~s|@description("Run a \\"shell\\" command")|
    end

    test "descriptions with newlines are collapsed to spaces" do
      defs = [
        tool_def(
          "bash",
          [cmd: [type: :string, required: true]],
          "First line.\nSecond line."
        )
      ]

      baml = SchemaWriter.to_baml(defs)
      assert baml =~ ~s|@description("First line. Second line.")|
    end

    test "no `Available actions:` catalog in the prompt" do
      defs = [tool_def("bash", cmd: [type: :string, required: true])]
      baml = SchemaWriter.to_baml(defs)

      refute baml =~ "Available actions:"
    end
  end

  describe "to_baml/2 — type mapping" do
    test "maps NimbleOptions types to BAML types" do
      defs = [
        tool_def("multi",
          s: [type: :string, required: true],
          i: [type: :integer, required: true],
          f: [type: :float, required: true],
          b: [type: :boolean, required: true],
          l: [type: {:list, :string}, required: true]
        )
      ]

      baml = SchemaWriter.to_baml(defs)

      assert baml =~ "  s string\n"
      assert baml =~ "  i int\n"
      assert baml =~ "  f float\n"
      assert baml =~ "  b bool\n"
      assert baml =~ "  l string[]\n"
    end
  end

  describe "to_baml/2 — client option" do
    test "default client is OpenRouter" do
      assert SchemaWriter.to_baml([]) =~ "client OpenRouter"
    end

    test "explicit client overrides default" do
      assert SchemaWriter.to_baml([], client: "Anthropic") =~ "client Anthropic"
    end
  end
end
