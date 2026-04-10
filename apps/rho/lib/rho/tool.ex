defmodule Rho.Tool do
  @moduledoc """
  Behaviour and DSL for defining agent tools with minimal boilerplate.

  ## Behaviour

  Modules that `use Rho.Tool` get a macro DSL, but the underlying contract
  is a plain behaviour with two callbacks:

    * `spec/0` — returns the `ReqLLM.Tool.t()` schema (name, description, params)
    * `run/2` — executes the tool with cast args and context

  ## DSL Usage

      defmodule MyApp.Tools.Weather do
        use Rho.Tool

        tool :get_weather, "Get current weather for a location" do
          param :location, :string, required: true, doc: "City name"
          param :units, :string, doc: "celsius or fahrenheit"

          run fn args, ctx ->
            Weather.fetch(args[:location], units: args[:units])
          end
        end
      end

  The macro generates:
  - A `ReqLLM.tool()` definition from the DSL (name, description, params)
  - Safe arg casting via declared schema keys only (delegates to `Rho.ToolArgs.cast/2`)
  - A `__tools__/1` function returning `[tool_def]` for plugin integration

  ## Result types

  Tools may return:
  - `{:ok, binary()}` — plain text result
  - `{:error, term()}` — error
  - `{:final, binary()}` — terminal result (ends the agent loop)
  - `%Rho.ToolResponse{}` — rich result with optional effects
  """

  @type result ::
          {:ok, String.t()}
          | {:error, term()}
          | {:final, String.t()}
          | Rho.ToolResponse.t()

  @callback spec() :: ReqLLM.Tool.t()
  @callback run(args :: map(), ctx :: Rho.Context.t()) :: result()

  @optional_callbacks spec: 0, run: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour Rho.Tool
      import Rho.Tool.DSL, only: [tool: 3, param: 2, param: 3, run: 1]
      Module.register_attribute(__MODULE__, :__rho_tools__, accumulate: true)

      @before_compile Rho.Tool.DSL
    end
  end
end
