defmodule Mix.Tasks.RhoFrameworks.DumpDedupPairs do
  @shortdoc "Dump LLM-confirmed semantic duplicate pairs for sanity-checking"

  @moduledoc """
  Runs the production dedup pipeline (semantic only) and writes every
  confirmed pair to a text file with both skill names and descriptions.
  Used to eyeball whether the LLM judgments look reasonable.

  ## Usage

      mix rho_frameworks.dump_dedup_pairs --library-id <uuid>
      mix rho_frameworks.dump_dedup_pairs --library-id <uuid> \\
        --output tmp/confirmed_pairs.txt
  """

  use Mix.Task

  alias RhoFrameworks.Frameworks.Library
  alias RhoFrameworks.Repo

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [library_id: :string, output: :string]
      )

    Mix.Task.run("app.start")

    library_id = opts[:library_id] || Mix.raise("--library-id required")
    output = opts[:output] || "tmp/confirmed_pairs.txt"

    library = Repo.get!(Library, library_id)

    Mix.shell().info("Running dedup pipeline on #{library.name}...")

    started = System.monotonic_time(:millisecond)

    dupes =
      RhoFrameworks.Library.find_duplicates(library_id, depth: :deep)
      |> Enum.filter(&(&1.detection_method == :semantic))

    elapsed = System.monotonic_time(:millisecond) - started

    File.mkdir_p!(Path.dirname(output))

    body =
      dupes
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {pair, idx} ->
        a = full_skill(pair.skill_a.id)
        b = full_skill(pair.skill_b.id)

        """
        [#{idx}] #{a.name}  ⟷  #{b.name}
            cat_A: #{a.category} | cat_B: #{b.category}
            desc_A: #{a.description || "(no description)"}
            desc_B: #{b.description || "(no description)"}
        """
        |> String.trim_trailing()
      end)

    File.write!(output, "Confirmed semantic duplicates: #{length(dupes)}\n\n" <> body <> "\n")

    Mix.shell().info("")
    Mix.shell().info("=== Summary ===")
    Mix.shell().info("Library: #{library.name}")
    Mix.shell().info("Confirmed semantic pairs: #{length(dupes)}")
    Mix.shell().info("Elapsed: #{elapsed}ms")
    Mix.shell().info("Wrote #{output}")
    Mix.shell().info("")
    Mix.shell().info("First 15 pairs:")
    Mix.shell().info(String.duplicate("-", 70))

    dupes
    |> Enum.take(15)
    |> Enum.with_index(1)
    |> Enum.each(fn {pair, idx} ->
      Mix.shell().info("[#{idx}] #{pair.skill_a.name}  ⟷  #{pair.skill_b.name}")
    end)
  end

  defp full_skill(id) do
    Repo.get!(RhoFrameworks.Frameworks.Skill, id)
  end
end
