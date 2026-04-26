defmodule Mix.Tasks.Rho.Run do
  @moduledoc false

  use Mix.Task

  @shortdoc "Send a one-shot message to the LLM"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [agent: :string, model: :string, system: :string, max_steps: :integer]
      )

    message = Enum.join(rest, " ")

    if message == "" do
      Mix.shell().error("Usage: mix rho.run [--agent name] \"your message here\"")
      exit({:shutdown, 1})
    end

    agent_name = if opts[:agent], do: String.to_existing_atom(opts[:agent]), else: :default

    case Rho.run(message, agent: agent_name) do
      {:ok, response} ->
        IO.puts(response)

      {:final, value} ->
        IO.puts(inspect(value))

      {:error, reason} ->
        Mix.shell().error("Error: #{reason}")
    end
  end
end
