defmodule Mix.Tasks.Rho.Debug do
  @moduledoc """
  Writes a portable debug bundle for a session, conversation, thread, or tape.
  """

  use Mix.Task

  @shortdoc "Create a Rho debug bundle"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _invalid} =
      OptionParser.parse(args,
        strict: [out: :string, last: :integer, format: :string],
        aliases: [o: :out, n: :last]
      )

    case rest do
      [ref] ->
        case Rho.Trace.Bundle.write(ref, opts) do
          {:ok, summary} ->
            Mix.shell().info("Wrote Rho debug bundle: #{summary["out_dir"]}")

          {:error, reason} ->
            Mix.raise("rho.debug failed: #{inspect(reason)}")
        end

      _ ->
        Mix.shell().info("""
        Usage: mix rho.debug <session_id | conversation_id | thread_id | tape_name> [options]

        Options:
          --out PATH      Output directory
          --last N        Include only the last N tape entries in exported reports
          --format FORMAT Reserved for future output formats
        """)
    end
  end
end
