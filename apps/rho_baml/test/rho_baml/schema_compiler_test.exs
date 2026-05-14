defmodule RhoBaml.SchemaCompilerTest do
  use ExUnit.Case, async: true

  alias RhoBaml.SchemaCompiler

  describe "to_baml_class/2 with primitives" do
    test "converts string, integer, float, boolean fields" do
      schema =
        Zoi.struct(TestPrimitives, %{
          name: Zoi.string(),
          count: Zoi.integer(),
          score: Zoi.float(),
          active: Zoi.boolean()
        })

      result = SchemaCompiler.to_baml_class(schema, "PrimitivesOutput")

      assert result =~ "class PrimitivesOutput {"
      assert result =~ "name string"
      assert result =~ "count int"
      assert result =~ "score float"
      assert result =~ "active bool"
    end

    test "converts array of primitives" do
      schema =
        Zoi.struct(TestArrays, %{
          indices: Zoi.array(Zoi.integer()),
          tags: Zoi.array(Zoi.string())
        })

      result = SchemaCompiler.to_baml_class(schema, "ArraysOutput")

      assert result =~ "indices int[]"
      assert result =~ "tags string[]"
    end
  end

  describe "to_baml_class/2 with descriptions" do
    test "adds @description annotations" do
      schema =
        Zoi.struct(TestDesc, %{
          indices: Zoi.array(Zoi.integer(), description: "1-based indices of most similar roles"),
          reasoning: Zoi.string(description: "Brief explanation")
        })

      result = SchemaCompiler.to_baml_class(schema, "DescOutput")

      assert result =~ ~s|indices int[] @description("1-based indices of most similar roles")|
      assert result =~ ~s|reasoning string @description("Brief explanation")|
    end
  end

  describe "to_baml_class/2 with optional fields" do
    test "marks optional fields with ?" do
      schema =
        Zoi.struct(TestOptional, %{
          required_field: Zoi.string(),
          optional_field: Zoi.string() |> Zoi.optional()
        })

      result = SchemaCompiler.to_baml_class(schema, "OptionalOutput")

      assert result =~ "required_field string\n"
      refute result =~ "required_field string?"
      assert result =~ "optional_field string?"
    end

    test "marks optional field with description" do
      schema =
        Zoi.struct(TestOptDesc, %{
          thinking: Zoi.string(description: "Reasoning") |> Zoi.optional()
        })

      result = SchemaCompiler.to_baml_class(schema, "OptDescOutput")

      assert result =~ ~s|thinking string? @description("Reasoning")|
    end
  end

  describe "to_baml_class/2 with nested types" do
    test "emits nested map as separate class" do
      schema =
        Zoi.struct(TestNested, %{
          scores:
            Zoi.array(
              Zoi.map(%{
                key: Zoi.string(description: "Variable key"),
                value: Zoi.float(description: "Score 0-100")
              })
            )
        })

      result = SchemaCompiler.to_baml_class(schema, "NestedOutput")

      # Nested class emitted before parent
      assert result =~ "class NestedOutputScores {"
      assert result =~ ~s|key string @description("Variable key")|
      assert result =~ ~s|value float @description("Score 0-100")|

      # Parent references nested class
      assert result =~ "scores NestedOutputScores[]"
    end
  end

  describe "to_baml_class/2 with Default-wrapped fields" do
    test "unwraps Default to get the underlying type" do
      schema =
        Zoi.struct(TestDefault, %{
          name: Zoi.string(),
          limit: Zoi.integer(description: "Max results") |> Zoi.default(10) |> Zoi.optional()
        })

      result = SchemaCompiler.to_baml_class(schema, "DefaultOutput")

      assert result =~ "name string"
      assert result =~ ~s|limit int? @description("Max results")|
    end
  end

  describe "to_baml_class/2 with Map schema" do
    test "accepts Zoi.map as input" do
      schema =
        Zoi.map(%{
          message: Zoi.string(),
          confidence: Zoi.float()
        })

      result = SchemaCompiler.to_baml_class(schema, "MapOutput")

      assert result =~ "class MapOutput {"
      assert result =~ "message string"
      assert result =~ "confidence float"
    end
  end

  describe "build_function_baml/6" do
    test "generates complete BAML function file" do
      schema =
        Zoi.struct(TestFunc, %{
          indices: Zoi.array(Zoi.integer(), description: "Ranked indices"),
          reasoning: Zoi.string(description: "Brief explanation")
        })

      class_baml = SchemaCompiler.to_baml_class(schema, "RankRolesOutput")

      result =
        SchemaCompiler.build_function_baml(
          class_baml,
          "RankRoles",
          "RankRolesOutput",
          [query: :string, role_list: :string, limit: :int],
          "OpenRouter",
          """
          You are a role matching assistant.
          Query: {{query}}
          Roles: {{role_list}}
          {{ ctx.output_format }}
          """
        )

      assert result =~ "class RankRolesOutput {"

      assert result =~
               "function RankRoles(query: string, role_list: string, limit: int) -> RankRolesOutput {"

      assert result =~ "client OpenRouter"
      assert result =~ "prompt #\""
      assert result =~ "{{ ctx.output_format }}"
      assert result =~ "\"#"
    end

    test "renders media params" do
      result =
        SchemaCompiler.build_function_baml(
          "class ExtractOutput {\n  ok bool\n}\n",
          "ExtractFromJDPdf",
          "ExtractOutput",
          [jd: :pdf],
          "AnthropicPdf",
          "{{ jd }}"
        )

      assert result =~ "function ExtractFromJDPdf(jd: pdf) -> ExtractOutput {"
    end
  end
end
