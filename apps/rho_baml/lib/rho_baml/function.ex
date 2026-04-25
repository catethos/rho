defmodule RhoBaml.Function do
  @moduledoc """
  `use` hook for defining BAML-backed LLM function modules.

  A thin `__before_compile__` hook that:

  1. Reads `@schema` and `@prompt` module attributes
  2. Converts the Zoi schema to a BAML class via `RhoBaml.SchemaCompiler`
  3. Writes the `.baml` file (class + function) to the consumer app's `priv/baml_src/functions/`
  4. Defines `call/2` and `stream/3` that delegate to `BamlElixir.Client`

  ## Usage

      defmodule MyApp.LLM.RankRoles do
        use RhoBaml.Function,
          client: "OpenRouter",
          params: [query: :string, role_list: :string, limit: :int]

        @schema Zoi.struct(__MODULE__, %{
          indices: Zoi.array(Zoi.integer(), description: "1-based indices of most similar roles"),
          reasoning: Zoi.string(description: "Brief explanation")
        })

        @enforce_keys Zoi.Struct.enforce_keys(@schema)
        defstruct Zoi.Struct.struct_fields(@schema)
        @type t :: unquote(Zoi.type_spec(@schema))

        @prompt ~S\"\"\"
        You are a role matching assistant.
        Query: {{query}}
        Roles: {{role_list}}
        Return at most {{limit}} indices.
        {{ ctx.output_format }}
        \"\"\"
      end

  This generates `call/2` and `stream/3`:

      {:ok, %RankRoles{indices: [1, 3], reasoning: "..."}} =
        MyApp.LLM.RankRoles.call(%{query: "backend dev", role_list: "...", limit: 3})

      # Override client at call time:
      MyApp.LLM.RankRoles.call(%{query: "..."}, llm_client: "Anthropic")
  """

  defmacro __using__(opts) do
    quote do
      @before_compile RhoBaml.Function
      @__baml_opts__ unquote(opts)
    end
  end

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :__baml_opts__)
    schema = Module.get_attribute(env.module, :schema)
    prompt = Module.get_attribute(env.module, :prompt)

    client = Keyword.fetch!(opts, :client)
    params = Keyword.fetch!(opts, :params)

    function_name = env.module |> Module.split() |> List.last()
    class_name = "#{function_name}Output"
    file_name = Macro.underscore(function_name)

    unless schema do
      raise CompileError,
        description: "#{inspect(env.module)} must define @schema before use RhoBaml.Function"
    end

    unless prompt do
      raise CompileError,
        description: "#{inspect(env.module)} must define @prompt before use RhoBaml.Function"
    end

    # Generate BAML content
    class_baml = RhoBaml.SchemaCompiler.to_baml_class(schema, class_name)

    baml_content =
      RhoBaml.SchemaCompiler.build_function_baml(
        class_baml,
        function_name,
        class_name,
        params,
        client,
        prompt
      )

    # Write .baml file to the consumer app's build priv directory
    priv_dir = Path.join(Mix.Project.app_path(), "priv")
    functions_dir = Path.join(priv_dir, "baml_src/functions")
    File.mkdir_p!(functions_dir)
    File.write!(Path.join(functions_dir, "#{file_name}.baml"), baml_content)

    app = Mix.Project.config()[:app]

    quote do
      @doc """
      Calls the `#{unquote(function_name)}` BAML function synchronously.

      ## Options
        - `:llm_client` — override the default BAML client
        - `:collectors` — list of `BamlElixir.Collector` for token tracking
      """
      def call(args, opts \\ []) do
        RhoBaml.Function.__call__(
          __MODULE__,
          unquote(function_name),
          unquote(app),
          args,
          opts
        )
      end

      @doc """
      Streams the `#{unquote(function_name)}` BAML function.

      The callback receives partial result maps as fields arrive.
      Returns `{:ok, %#{inspect(unquote(env.module))}{}}` on completion.

      ## Options
        - `:llm_client` — override the default BAML client
        - `:collectors` — list of `BamlElixir.Collector` for token tracking
      """
      def stream(args, callback, opts \\ []) do
        RhoBaml.Function.__stream__(
          __MODULE__,
          unquote(function_name),
          unquote(app),
          args,
          callback,
          opts
        )
      end
    end
  end

  # -- Runtime dispatch --

  @doc false
  def __call__(module, function_name, app, args, opts) do
    baml_path = RhoBaml.baml_path(app)
    call_opts = build_opts(baml_path, opts)

    case BamlElixir.Client.call(function_name, args, call_opts) do
      {:ok, result} ->
        {:ok, to_struct(module, result)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def __stream__(module, function_name, app, args, callback, opts) do
    baml_path = RhoBaml.baml_path(app)
    call_opts = build_opts(baml_path, opts)

    case BamlElixir.Client.sync_stream(function_name, args, callback, call_opts) do
      {:ok, result} ->
        {:ok, to_struct(module, result)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_opts(baml_path, opts) do
    base = %{path: baml_path, parse: false}

    base
    |> maybe_put(:llm_client, Keyword.get(opts, :llm_client))
    |> maybe_put(:collectors, Keyword.get(opts, :collectors))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_struct(module, result) do
    result
    |> Map.drop([:__baml_class__])
    |> then(&struct!(module, &1))
  end
end
