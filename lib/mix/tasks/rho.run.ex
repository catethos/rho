defmodule Mix.Tasks.Rho.Run do
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

    agent_name = if opts[:agent], do: String.to_atom(opts[:agent]), else: :default
    config = Rho.Config.agent(agent_name)

    model = opts[:model] || config.model
    messages = [ReqLLM.Context.user(message)]

    run_opts =
      [
        system_prompt: opts[:system] || config.system_prompt,
        tools:
          Rho.MountRegistry.collect_tools(%{
            workspace: File.cwd!(),
            agent_name: agent_name,
            depth: 0,
            sandbox: nil
          }),
        max_steps: opts[:max_steps] || config.max_steps,
        reasoner: config.reasoner
      ]
      |> then(fn o ->
        if config.provider, do: Keyword.put(o, :provider, config.provider), else: o
      end)

    case Rho.AgentLoop.run(model, messages, run_opts) do
      {:ok, response} ->
        IO.puts(response)

      {:error, reason} ->
        Mix.shell().error("Error: #{reason}")
    end
  end
end
