defmodule RhoBaml.SchemaWriter do
  @moduledoc """
  Generates dynamic `.baml` files from NimbleOptions tool_defs at runtime.

  Used by `TypedStructured` to produce a BAML Action schema that replaces
  both `ActionSchema.render_prompt/1` (prompt injection) and
  `StructuredOutput.parse/1` (response parsing). BAML re-reads `.baml` files
  on every call, so the schema can change between turns.

  ## Generated BAML

  Produces an `Action` class with:
  - `tool` — string discriminant (required)
  - All tool params flattened and made optional (only one tool's params are relevant per response)
  - `thinking` — optional reasoning side-channel

  Plus an `AgentTurn` function wired to a configurable client.
  """

  @type tool_def :: %{
          tool: %{name: String.t(), parameter_schema: keyword(), description: String.t()}
        }

  @doc """
  Writes dynamic `.baml` files to `dir` from the given tool_defs.

  When `:model` is provided (e.g., `"openrouter:deepseek/deepseek-chat-v3-0324"`),
  generates a dynamic client config so the BAML call uses the correct provider
  and model. The client name used in the AgentTurn function matches the generated
  client.

  Returns `:ok`.

  ## Options
    - `:model` — model string in `"provider:model_id"` format (generates dynamic client)
    - `:client` — explicit BAML client name override (default: derived from model or `"OpenRouter"`)
  """
  @spec write!(String.t(), [tool_def()], keyword()) :: :ok
  def write!(dir, tool_defs, opts \\ []) do
    dynamic_dir = Path.join(dir, "dynamic")
    File.mkdir_p!(dynamic_dir)

    # Generate client config from model string if provided
    opts = maybe_generate_client(dynamic_dir, opts)

    baml = to_baml(tool_defs, opts)
    File.write!(Path.join(dynamic_dir, "action.baml"), baml)
    :ok
  end

  @doc """
  Generates the BAML string for an Action schema from tool_defs.

  Does not write to disk — useful for testing and inspection.
  """
  @spec to_baml([tool_def()], keyword()) :: String.t()
  def to_baml(tool_defs, opts \\ []) do
    client = Keyword.get(opts, :client, "OpenRouter")
    visible_defs = Enum.reject(tool_defs, fn td -> td[:deferred] end)

    builtin_fields = [
      {"message", "string"},
      {"thought", "string"}
    ]

    tool_fields = collect_fields(visible_defs)
    all_fields = builtin_fields ++ tool_fields

    # Deduplicate by field name, keeping first occurrence
    unique_fields =
      all_fields
      |> Enum.uniq_by(fn {name, _type} -> name end)

    fields_baml =
      Enum.map_join(unique_fields, "\n", fn {name, type} ->
        "  #{name} #{type}?"
      end)

    tool_names =
      ["respond", "think" | Enum.map(visible_defs, & &1.tool.name)]
      |> Enum.join(", ")

    """
    class Action {
      tool string @description("One of: #{tool_names}")
    #{fields_baml}
      thinking string?
    }

    function AgentTurn(messages: string) -> Action {
      client #{client}
      prompt #"
        {{ messages }}

        {{ ctx.output_format }}
      "#
    }
    """
  end

  # -- Field collection --

  defp collect_fields(tool_defs) do
    Enum.flat_map(tool_defs, fn td ->
      schema = td.tool.parameter_schema || []

      Enum.map(schema, fn {name, opts} ->
        type = Keyword.get(opts, :type, :string) |> to_baml_type()
        {Atom.to_string(name), type}
      end)
    end)
  end

  # -- Dynamic client generation --

  defp maybe_generate_client(dynamic_dir, opts) do
    case Keyword.get(opts, :model) do
      nil ->
        opts

      model when is_binary(model) ->
        case parse_model(model) do
          {:ok, provider, model_id, client_name} ->
            client_baml = build_client_baml(client_name, provider, model_id)
            File.write!(Path.join(dynamic_dir, "client.baml"), client_baml)
            Keyword.put(opts, :client, client_name)

          :error ->
            opts
        end
    end
  end

  defp parse_model(model) do
    case String.split(model, ":", parts: 2) do
      [provider_prefix, model_id] ->
        case provider_config(provider_prefix) do
          {:ok, baml_provider, env_key, base_url} ->
            client_name = camelize_provider(provider_prefix)
            {:ok, {baml_provider, env_key, base_url, model_id}, model_id, client_name}

          :error ->
            :error
        end

      _ ->
        :error
    end
  end

  defp build_client_baml(client_name, {baml_provider, env_key, nil, model_id}, _model_id) do
    """
    client #{client_name} {
      provider "#{baml_provider}"
      options {
        model "#{model_id}"
        api_key env.#{env_key}
      }
    }
    """
  end

  defp build_client_baml(client_name, {baml_provider, env_key, base_url, model_id}, _model_id) do
    """
    client #{client_name} {
      provider "#{baml_provider}"
      options {
        base_url "#{base_url}"
        model "#{model_id}"
        api_key env.#{env_key}
      }
    }
    """
  end

  @provider_map %{
    "openrouter" => {"openai-generic", "OPENROUTER_API_KEY", "https://openrouter.ai/api/v1"},
    "anthropic" => {"anthropic", "ANTHROPIC_API_KEY", nil},
    "openai" => {"openai", "OPENAI_API_KEY", nil},
    "fireworks_ai" =>
      {"openai-generic", "FIREWORKS_API_KEY", "https://api.fireworks.ai/inference/v1"},
    "groq" => {"openai-generic", "GROQ_API_KEY", "https://api.groq.com/openai/v1"},
    "google" => {"google-ai", "GOOGLE_API_KEY", nil}
  }

  defp provider_config(prefix) do
    case Map.get(@provider_map, prefix) do
      {baml_provider, env_key, base_url} -> {:ok, baml_provider, env_key, base_url}
      nil -> :error
    end
  end

  defp camelize_provider(prefix) do
    prefix
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
  end

  # -- Type mapping (NimbleOptions → BAML) --

  defp to_baml_type(:string), do: "string"
  defp to_baml_type(:integer), do: "int"
  defp to_baml_type(:pos_integer), do: "int"
  defp to_baml_type(:float), do: "float"
  defp to_baml_type(:number), do: "float"
  defp to_baml_type(:boolean), do: "bool"
  defp to_baml_type(:map), do: "string"
  defp to_baml_type({:list, inner}), do: "#{to_baml_type(inner)}[]"
  defp to_baml_type({:in, _variants}), do: "string"
  defp to_baml_type({:map, _k, _v}), do: "string"
  defp to_baml_type(_), do: "string"
end
