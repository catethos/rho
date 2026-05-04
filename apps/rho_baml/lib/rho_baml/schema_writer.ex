defmodule RhoBaml.SchemaWriter do
  @moduledoc """
  Generates dynamic `.baml` files from NimbleOptions tool_defs at runtime.

  Used by `TypedStructured` to produce a BAML Action schema that replaces
  both `ActionSchema.render_prompt/1` (prompt injection) and
  `StructuredOutput.parse/1` (response parsing). BAML re-reads `.baml` files
  on every call, so the schema can change between turns.

  ## Generated BAML

  Produces a **discriminated union** of per-tool action classes:

  - `RespondAction` — `tool "respond"`, `message string`, optional `kind string?`
  - `ThinkAction` — `tool "think"`, `thought string`
  - One class per visible tool — `tool "<name>"` (literal), declared params
    (required vs optional preserved from the parameter_schema)

  No auto-injected `thinking` field — use the dedicated `:think` tool when
  the model needs an explicit reasoning step.

  Plus an `AgentTurn(messages: string)` function returning the union, wired
  to a configurable client. The LLM picks one variant and emits only its
  fields — no `null` padding for unused tool params.
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
    write_if_changed(Path.join(dynamic_dir, "action.baml"), baml)
    :ok
  end

  # Read the existing file and only rewrite when bytes differ. BAML
  # re-reads on every `sync_stream` so a no-op write is harmless, but
  # cuts disk I/O on every turn when nothing changed.
  defp write_if_changed(path, bytes) do
    case File.read(path) do
      {:ok, ^bytes} -> :ok
      _ -> File.write!(path, bytes)
    end
  end

  @doc """
  Generates the BAML string for an Action schema from tool_defs.

  Does not write to disk — useful for testing and inspection.
  """
  @spec to_baml([tool_def()], keyword()) :: String.t()
  def to_baml(tool_defs, opts \\ []) do
    client = Keyword.get(opts, :client, "OpenRouter")
    visible_defs = Enum.reject(tool_defs, fn td -> td[:deferred] end)

    reserved = [
      {"RespondAction", "respond",
       "Reply directly to the user. The ONLY way to send text to the user — use it for answers, " <>
         "summaries, follow-up questions, error reports, and clarification requests. " <>
         "When you are missing information, blocked, or uncertain, ALWAYS use respond " <>
         "(set kind to question, error, or clarification) instead of free-text — " <>
         "never write user-facing prose outside this action.",
       [{"message", "string"}, {"kind", "string?"}]},
      {"ThinkAction", "think", "Record an internal reasoning step without external action.",
       [{"thought", "string"}]}
    ]

    tool_variants =
      Enum.map(visible_defs, fn td ->
        {tool_name_to_class(td.tool.name), td.tool.name,
         td.tool.description |> to_string() |> sanitize_desc(),
         render_variant_fields(td.tool.parameter_schema || [])}
      end)

    all_variants = reserved ++ tool_variants

    classes_baml =
      Enum.map_join(all_variants, "\n\n", fn {class_name, tool_lit, desc, fields} ->
        build_variant_class(class_name, tool_lit, desc, fields)
      end)

    union_type =
      all_variants
      |> Enum.map(&elem(&1, 0))
      |> Enum.join(" | ")

    """
    #{classes_baml}

    function AgentTurn(messages: string) -> #{union_type} {
      client #{client}
      prompt #"
        {{ messages }}

        {{ ctx.output_format }}

        Reply with exactly one JSON object matching one of the schemas above.
        It must include the "tool" discriminator field. Do not write any prose,
        commentary, or explanation outside the JSON object — if you need to
        speak to the user, use the "respond" action and put the text in its
        "message" field.
      "#
    }
    """
  end

  defp build_variant_class(class_name, tool_lit, desc, fields) do
    tool_line =
      case desc do
        "" -> "  tool \"#{tool_lit}\""
        d -> "  tool \"#{tool_lit}\" @description(\"#{d}\")"
      end

    fields_baml =
      Enum.map_join(fields, "\n", fn {name, type} -> "  #{name} #{type}" end)

    body =
      case fields_baml do
        "" -> tool_line
        nb -> "#{tool_line}\n#{nb}"
      end

    "class #{class_name} {\n#{body}\n}"
  end

  defp render_variant_fields(schema) do
    Enum.map(schema, fn {name, opts} ->
      base = Keyword.get(opts, :type, :string) |> to_baml_type()
      type = if Keyword.get(opts, :required, false), do: base, else: "#{base}?"
      {Atom.to_string(name), type}
    end)
  end

  defp tool_name_to_class(name) do
    Macro.camelize(to_string(name)) <> "Action"
  end

  # Description renders inside `@description("...")` — escape backslash and
  # double-quote, collapse newlines.
  defp sanitize_desc(desc) do
    desc
    |> String.trim()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", " ")
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
            write_if_changed(Path.join(dynamic_dir, "client.baml"), client_baml)
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
