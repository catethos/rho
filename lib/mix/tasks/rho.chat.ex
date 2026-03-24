defmodule Mix.Tasks.Rho.Chat do
  use Mix.Task

  @shortdoc "Start an interactive chat session with the LLM"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          agent: :string,
          model: :string,
          system: :string,
          max_steps: :integer,
          session: :string
        ]
      )

    agent_name = if opts[:agent], do: String.to_atom(opts[:agent]), else: :default
    config = Rho.Config.agent(agent_name)
    model = opts[:model] || config.model

    IO.puts("rho — interactive chat (Ctrl-C to quit)")
    IO.puts("Agent: #{agent_name} | Model: #{model}")
    if opts[:session], do: IO.puts("Session: #{opts[:session]}")
    IO.puts("")

    session_id = opts[:session] || "cli:default"

    session_opts =
      [agent_name: agent_name]
      |> maybe_put(:model, opts[:model])
      |> maybe_put(:system_prompt, opts[:system])
      |> maybe_put(:max_steps, opts[:max_steps])

    Rho.CLI.start_repl(session_id, [
      {:group_leader, Process.group_leader()},
      {:stop_event, self()}
      | session_opts
    ])

    # Block until stop
    receive do
      :stop -> :ok
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
