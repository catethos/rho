defmodule Rho.Stdlib.Plugins.PyAgent do
  @moduledoc """
  Mount that bridges a pydantic-ai (or any Python) agent into Rho via erlang_python.

  Communication is text-level: the Python agent receives a string message and returns
  a string response. No behaviour conformance required on the Python side — just
  `chat(session_id, message) -> str`.

  ## Config

      # .rho.exs
      mounts: [{:py_agent, module: "example_agent", name: "researcher"}]

  Options:
    - `:module` — Python module name (must be importable, added to sys.path)
    - `:name` — tool name suffix, defaults to module name
    - `:description` — override the tool description (otherwise fetched from Python)
  """

  @behaviour Rho.Plugin

  @impl Rho.Plugin
  def tools(mount_opts, context) do
    module_str = Keyword.fetch!(mount_opts, :module)

    case safe_existing_atom(module_str) do
      nil -> []
      py_module -> build_tools(py_module, mount_opts, context)
    end
  end

  defp build_tools(py_module, mount_opts, context) do
    name = Keyword.get(mount_opts, :name, to_string(py_module))
    description = resolve_description(py_module, mount_opts, name)

    [
      %{
        tool:
          ReqLLM.tool(
            name: "ask_#{name}",
            description: description,
            parameter_schema: [
              message: [type: :string, required: true, doc: "The message to send to the agent"]
            ],
            callback: fn _args -> :ok end
          ),
        execute: fn %{"message" => message}, _ctx ->
          session_id = context[:session_id] || context[:agent_id] || "default"
          call_py_agent(py_module, session_id, message)
        end
      }
    ]
  end

  defp resolve_description(py_module, mount_opts, name) do
    case Keyword.fetch(mount_opts, :description) do
      {:ok, desc} ->
        desc

      :error ->
        case :py.call(py_module, :describe, []) do
          {:ok, %{"description" => desc}} -> desc
          _ -> "Talk to the #{name} Python agent"
        end
    end
  end

  defp call_py_agent(py_module, session_id, message) do
    case :py.call(py_module, :chat, [session_id, message]) do
      {:ok, response} when is_binary(response) ->
        {:ok, response}

      {:ok, response} ->
        {:ok, inspect(response)}

      {:error, {exc_type, exc_msg}} ->
        {:error, "Python #{exc_type}: #{exc_msg}"}

      {:error, reason} ->
        {:error, "Python agent error: #{inspect(reason)}"}
    end
  end

  defp safe_existing_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end
end
