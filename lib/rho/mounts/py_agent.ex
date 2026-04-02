defmodule Rho.Mounts.PyAgent do
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

  @behaviour Rho.Mount

  @impl Rho.Mount
  def tools(mount_opts, context) do
    py_module = Keyword.fetch!(mount_opts, :module) |> String.to_existing_atom()
    name = Keyword.get(mount_opts, :name, to_string(py_module))

    # Fetch agent metadata from Python
    description =
      case Keyword.fetch(mount_opts, :description) do
        {:ok, desc} ->
          desc

        :error ->
          case :py.call(py_module, :describe, []) do
            {:ok, %{"description" => desc}} -> desc
            _ -> "Talk to the #{name} Python agent"
          end
      end

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
        execute: fn %{"message" => message} ->
          session_id = context[:session_id] || context[:agent_id] || "default"

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
      }
    ]
  end
end
