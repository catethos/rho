defmodule Rho.ActionSchema do
  @moduledoc """
  Tagged union builder for the TypedStructured strategy.

  Converts tool_defs into a closed discriminated union where every possible
  LLM response maps to exactly one variant. Built-in variants `respond` and
  `think` are reserved.

  ## Format

  Flat JSON with `"tool"` as discriminant:

      {"tool": "bash", "cmd": "ls -la", "thinking": "Check directory"}
      {"tool": "respond", "message": "Here is your answer."}
      {"tool": "think", "thought": "I need to reconsider..."}
  """

  alias Rho.{SchemaCoerce, StructuredOutput}

  @type variant :: %{
          name: String.t(),
          fields: keyword(),
          builtin: boolean()
        }

  @type t :: %__MODULE__{
          variants: %{String.t() => variant()},
          tag_key: String.t()
        }

  defstruct variants: %{}, tag_key: "tool"

  @reserved_variants %{
    "respond" => %{
      name: "respond",
      fields: [message: [type: :string, required: true, doc: "Response message to the user"]],
      builtin: true
    },
    "think" => %{
      name: "think",
      fields: [thought: [type: :string, required: true, doc: "Reasoning step"]],
      builtin: true
    }
  }

  # --- Build ---

  @doc """
  Build a tagged union schema from tool_defs.

  Adds built-in `respond` and `think` variants. Raises on reserved name
  collisions or duplicate tool names.
  """
  @spec build([map()]) :: t()
  def build(tool_defs) do
    reserved = Map.keys(@reserved_variants) |> MapSet.new()
    tool_names = Enum.map(tool_defs, & &1.tool.name)

    for name <- tool_names, name in reserved do
      raise ArgumentError,
            "Tool name #{inspect(name)} collides with built-in action. " <>
              "Rename the tool or use a prefix."
    end

    dupes = tool_names -- Enum.uniq(tool_names)

    if dupes != [] do
      raise ArgumentError,
            "Duplicate tool names: #{inspect(Enum.uniq(dupes))}. " <>
              "Each tool must have a unique name."
    end

    tool_variants =
      Map.new(tool_defs, fn td ->
        {td.tool.name,
         %{
           name: td.tool.name,
           fields: td.tool.parameter_schema || [],
           builtin: false
         }}
      end)

    %__MODULE__{
      variants: Map.merge(@reserved_variants, tool_variants),
      tag_key: "tool"
    }
  end

  # --- Parse and dispatch ---

  @doc """
  Parse raw LLM text and dispatch to the matching variant.

  Pipeline: StructuredOutput.parse → extract "tool" tag →
  find variant → coerce fields → extract thinking side-channel.

  Returns one of:
    - `{:respond, message, thinking: thinking}`
    - `{:think, thought}`
    - `{:tool, name, args, tool_def, thinking: thinking, repairs: repairs}`
    - `{:unknown, name, raw_args}`
    - `{:parse_error, reason}`
  """
  @spec parse_and_dispatch(String.t(), t(), %{String.t() => map()}) ::
          {:respond, String.t(), keyword()}
          | {:think, String.t()}
          | {:tool, String.t(), map(), map(), keyword()}
          | {:unknown, String.t(), map()}
          | {:parse_error, term()}
  def parse_and_dispatch(text, schema, tool_map) do
    case StructuredOutput.parse(text) do
      {:ok, parsed} when is_map(parsed) ->
        dispatch(parsed, schema, tool_map)

      {:ok, _non_map} ->
        {:parse_error, :not_an_object}

      {:error, reason} ->
        {:parse_error, reason}
    end
  end

  # --- Prompt rendering ---

  @doc """
  Render BAML-style schema text for prompt injection.
  """
  @spec render_prompt(t()) :: String.t()
  def render_prompt(%__MODULE__{variants: variants}) do
    sorted =
      variants
      |> Map.values()
      |> Enum.sort_by(fn v -> {!v.builtin, v.name} end)

    variant_lines =
      Enum.map_join(sorted, "\n", fn variant ->
        params = render_fields(variant.fields)
        "  | #{variant.name}(#{params})"
      end)

    """
    Action = {
      tool: ActionName,  // discriminant
      ...params,         // fields for the chosen action
      thinking?: string  // optional reasoning (any action)
    }

    ActionName =
    #{variant_lines}
    """
  end

  # --- Internals ---

  defp dispatch(parsed, schema, tool_map) do
    case Map.get(parsed, schema.tag_key) do
      nil ->
        {:parse_error, :missing_tool_tag}

      tag when is_binary(tag) ->
        thinking = Map.get(parsed, "thinking")
        thinking = if is_binary(thinking) and thinking != "", do: thinking
        args = Map.drop(parsed, [schema.tag_key, "thinking"])

        case Map.get(schema.variants, tag) do
          nil ->
            {:unknown, tag, args}

          %{builtin: true, name: "respond", fields: fields} ->
            dispatch_respond(args, fields, thinking)

          %{builtin: true, name: "think"} ->
            thought = thinking || Map.get(args, "thought") || Map.get(args, :thought) || ""
            {:think, thought}

          %{builtin: false, name: name} ->
            dispatch_tool_call(name, args, tool_map, thinking)
        end

      _non_string ->
        {:parse_error, :tool_tag_not_string}
    end
  end

  defp dispatch_respond(args, fields, thinking) do
    case coerce_variant_fields(args, fields) do
      {:ok, coerced, _repairs} ->
        {:respond, coerced[:message] || "", thinking: thinking}

      {:error, reason} ->
        {:parse_error, {:coerce_failed, "respond", reason}}
    end
  end

  defp dispatch_tool_call(name, args, tool_map, thinking) do
    case Map.get(tool_map, name) do
      nil ->
        {:unknown, name, args}

      tool_def ->
        fields = tool_def.tool.parameter_schema || []

        case coerce_variant_fields(args, fields) do
          {:ok, coerced, repairs} ->
            {:tool, name, coerced, tool_def, thinking: thinking, repairs: repairs}

          {:error, reason} ->
            {:parse_error, {:coerce_failed, name, reason}}
        end
    end
  end

  defp coerce_variant_fields(args, fields) do
    cast = Rho.ToolArgs.cast(args, fields)

    case SchemaCoerce.coerce_fields(cast, fields, mode: :tool_call) do
      {:ok, coerced, field_repairs} ->
        {:ok, coerced, field_repairs}

      {:error, _} = err ->
        err
    end
  end

  defp render_fields([]), do: ""

  defp render_fields(fields) do
    Enum.map_join(fields, ", ", fn {name, opts} ->
      type = Keyword.get(opts, :type, :string) |> render_type()
      optional = if Keyword.get(opts, :required, false), do: "", else: "?"
      "#{name}#{optional}: #{type}"
    end)
  end

  defp render_type({:list, inner}), do: "#{render_type(inner)}[]"
  defp render_type({:map, k, v}), do: "map<#{render_type(k)}, #{render_type(v)}>"
  defp render_type(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp render_type(_), do: "any"
end
