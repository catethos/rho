defmodule RhoBaml.SchemaCompiler do
  @moduledoc """
  Converts Zoi schemas to BAML class definitions.

  Handles primitive types (string, int, float, bool), arrays, optional fields,
  descriptions, and nested map/struct types (emitted as separate BAML classes).

  ## Example

      schema = Zoi.struct(MyModule, %{
        indices: Zoi.array(Zoi.integer(), description: "1-based indices"),
        reasoning: Zoi.string(description: "Brief explanation")
      })

      RhoBaml.SchemaCompiler.to_baml_class(schema, "RankRolesOutput")
      # => "class RankRolesOutput {\\n  indices int[] @description(\\"1-based indices\\")\\n  ...\\n}"
  """

  @doc """
  Converts a Zoi struct or map schema to one or more BAML class definitions.

  Returns a string containing all class definitions needed (nested types are
  emitted as separate classes before the parent class).
  """
  def to_baml_class(schema, class_name) do
    {classes, _type_name} = compile_class(schema, class_name, [])
    classes |> Enum.reverse() |> Enum.join("\n")
  end

  # -- Class compilation --

  defp compile_class(%Zoi.Types.Struct{fields: fields}, class_name, acc) when is_list(fields) do
    do_compile_class(fields, class_name, acc)
  end

  defp compile_class(%Zoi.Types.Map{fields: fields}, class_name, acc) when is_list(fields) do
    do_compile_class(fields, class_name, acc)
  end

  defp do_compile_class(fields, class_name, acc) do
    {lines, acc} =
      Enum.reduce(fields, {[], acc}, fn {key, type}, {lines, acc} ->
        nested_name = "#{class_name}#{camelize(key)}"
        {baml_type, acc} = resolve_type(unwrap(type), nested_name, acc)

        optional_mark = if optional?(type), do: "?", else: ""

        desc_mark =
          case description(type) do
            nil -> ""
            desc -> " @description(#{inspect(desc)})"
          end

        line = "  #{key} #{baml_type}#{optional_mark}#{desc_mark}"
        {[line | lines], acc}
      end)

    class_def = "class #{class_name} {\n#{lines |> Enum.reverse() |> Enum.join("\n")}\n}\n"
    {[class_def | acc], class_name}
  end

  # -- Type resolution --

  defp resolve_type(%Zoi.Types.String{}, _nested_name, acc), do: {"string", acc}
  defp resolve_type(%Zoi.Types.Integer{}, _nested_name, acc), do: {"int", acc}
  defp resolve_type(%Zoi.Types.Float{}, _nested_name, acc), do: {"float", acc}
  defp resolve_type(%Zoi.Types.Boolean{}, _nested_name, acc), do: {"bool", acc}

  defp resolve_type(%Zoi.Types.Array{inner: inner}, nested_name, acc) do
    {inner_type, acc} = resolve_type(inner, nested_name, acc)
    {"#{inner_type}[]", acc}
  end

  defp resolve_type(%Zoi.Types.Map{fields: fields} = map, nested_name, acc)
       when is_list(fields) do
    {acc, type_name} = compile_class(map, nested_name, acc)
    {type_name, acc}
  end

  defp resolve_type(%Zoi.Types.Struct{fields: fields} = struct, nested_name, acc)
       when is_list(fields) do
    {acc, type_name} = compile_class(struct, nested_name, acc)
    {type_name, acc}
  end

  defp resolve_type(type, _nested_name, _acc) do
    raise ArgumentError,
          "Unsupported Zoi type for BAML conversion: #{inspect(type.__struct__)}"
  end

  # -- Field introspection helpers --

  # Unwrap Default wrapper to get the underlying type for BAML type mapping.
  defp unwrap(%Zoi.Types.Default{inner: inner}), do: inner
  defp unwrap(type), do: type

  # A field is optional when meta.required is explicitly false.
  defp optional?(%Zoi.Types.Default{meta: %{required: false}}), do: true
  defp optional?(%Zoi.Types.Default{inner: inner}), do: optional?(inner)
  defp optional?(%{meta: %{required: false}}), do: true
  defp optional?(_), do: false

  # Description may live on the outer wrapper or the inner type.
  defp description(%Zoi.Types.Default{meta: %{description: desc}}) when is_binary(desc), do: desc
  defp description(%Zoi.Types.Default{inner: inner}), do: description(inner)
  defp description(%{meta: %{description: desc}}) when is_binary(desc), do: desc
  defp description(_), do: nil

  defp camelize(atom) when is_atom(atom), do: atom |> Atom.to_string() |> camelize()

  defp camelize(string) do
    string |> String.split("_") |> Enum.map(&String.capitalize/1) |> Enum.join()
  end

  # -- BAML function file generation (used by RhoBaml.Function) --

  @doc false
  def build_function_baml(class_baml, function_name, class_name, params, client, prompt) do
    params_str =
      Enum.map_join(params, ", ", fn {name, type} ->
        "#{name}: #{param_type(type)}"
      end)

    """
    #{class_baml}
    function #{function_name}(#{params_str}) -> #{class_name} {
      client #{client}
      prompt #"
    #{indent_prompt(prompt)}
      "#
    }
    """
  end

  defp param_type(:string), do: "string"
  defp param_type(:int), do: "int"
  defp param_type(:float), do: "float"
  defp param_type(:bool), do: "bool"

  defp indent_prompt(prompt) do
    prompt
    |> String.trim()
    |> String.split("\n")
    |> Enum.map_join("\n", &"    #{&1}")
  end
end
