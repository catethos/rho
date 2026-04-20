defmodule Rho.Tool.DSL do
  @moduledoc false
  # Compile-time DSL for `use Rho.Tool`.
  #
  # Each `tool` block generates a named private function for the run
  # callback, avoiding the need to store anonymous function AST in
  # module attributes. `__before_compile__` wires up `__tools__/1`.

  @doc """
  Define a tool with name, description, params, and a run function.

      tool :my_tool, "Does something useful" do
        param :name, :string, required: true, doc: "The name"
        run fn args, ctx -> {:ok, args[:name]} end
      end
  """
  defmacro tool(name, description, do: block) do
    quote do
      @__rho_current_tool_name__ unquote(name)
      @__rho_current_tool_desc__ unquote(description)
      Module.register_attribute(__MODULE__, :__rho_current_params__, accumulate: true)
      Module.put_attribute(__MODULE__, :__rho_current_run_ast__, nil)

      unquote(block)

      params = Module.get_attribute(__MODULE__, :__rho_current_params__) |> Enum.reverse()
      run_ast = Module.get_attribute(__MODULE__, :__rho_current_run_ast__)
      tool_name = Module.get_attribute(__MODULE__, :__rho_current_tool_name__)
      tool_desc = Module.get_attribute(__MODULE__, :__rho_current_tool_desc__)

      unless run_ast do
        raise CompileError,
          description:
            "tool #{inspect(tool_name)} is missing a `run fn args, ctx -> ... end` block"
      end

      @__rho_tools__ %{
        name: tool_name,
        description: tool_desc,
        params: params,
        run_ast: run_ast
      }

      Module.delete_attribute(__MODULE__, :__rho_current_params__)
      Module.delete_attribute(__MODULE__, :__rho_current_run_ast__)
      Module.delete_attribute(__MODULE__, :__rho_current_tool_name__)
      Module.delete_attribute(__MODULE__, :__rho_current_tool_desc__)
    end
  end

  @doc false
  defmacro param(name, type, opts \\ []) do
    quote do
      @__rho_current_params__ {unquote(name), unquote(type), unquote(opts)}
    end
  end

  @doc false
  defmacro run(func) do
    escaped = Macro.escape(func)

    quote do
      Module.put_attribute(__MODULE__, :__rho_current_run_ast__, unquote(escaped))
    end
  end

  defmacro __before_compile__(env) do
    tools = Module.get_attribute(env.module, :__rho_tools__) |> Enum.reverse()

    tool_defs =
      Enum.map(tools, fn tool ->
        param_schema = build_param_schema(tool.params)
        tool_name_str = Atom.to_string(tool.name)
        run_ast = tool.run_ast

        quote do
          %{
            tool:
              ReqLLM.tool(
                name: unquote(tool_name_str),
                description: unquote(tool.description),
                parameter_schema: unquote(param_schema),
                callback: fn _ -> :ok end
              ),
            execute: fn args, ctx ->
              schema = unquote(param_schema)

              case Rho.ToolArgs.prepare(args, schema) do
                {:ok, prepared, _repairs} ->
                  unquote(run_ast).(prepared, ctx)

                {:error, {:missing_required, field}} ->
                  {:error, "Missing required parameter(s): #{field}"}

                {:error, keys} when is_list(keys) ->
                  names = Enum.map_join(keys, ", ", &Atom.to_string/1)
                  {:error, "Missing required parameter(s): #{names}"}

                {:error, reason} ->
                  {:error, "Arg preparation failed: #{inspect(reason)}"}
              end
            end
          }
        end
      end)

    quote do
      import Rho.Tool.DSL, only: [tool: 3, param: 2, param: 3, run: 1]

      @doc """
      Returns tool_def maps for all tools defined in this module.
      Accepts a context map (for forward compatibility) but currently ignores it.
      """
      @spec __tools__(map()) :: [Rho.Plugin.tool_def()]
      def __tools__(_context \\ %{}) do
        unquote(tool_defs)
      end
    end
  end

  # -- Helpers (compile-time) --

  defp build_param_schema(params) do
    Enum.map(params, fn {name, type, opts} ->
      schema_opts =
        [type: type]
        |> maybe_add(:required, Keyword.get(opts, :required))
        |> maybe_add(:doc, Keyword.get(opts, :doc))

      {name, schema_opts}
    end)
  end

  defp maybe_add(kw, _key, nil), do: kw
  defp maybe_add(kw, key, value), do: Keyword.put(kw, key, value)
end
