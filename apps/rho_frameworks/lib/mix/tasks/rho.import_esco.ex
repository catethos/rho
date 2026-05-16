defmodule Mix.Tasks.Rho.ImportEsco do
  use Mix.Task

  @shortdoc "Import the ESCO classification (skills + occupations) from a CSV directory"

  @moduledoc """
  Import the [ESCO v1.2.1](https://esco.ec.europa.eu/) classification — ~13,960
  skills, ~3,008 occupations, ~126,000 occupation↔skill links — into the
  `rho_frameworks` database as a public, immutable library owned by the
  `system` organization.

  The CSV bundle must be the official ESCO `_en` download. We use four files
  out of the 19; see `RhoFrameworks.Import.Esco` for the column mapping.

  ## Usage

      # parse only — no DB writes (used by tests + as a sanity check)
      mix rho.import_esco /path/to/esco-1.2.1 --dry-run

      # full import (skeleton phase: parse + summary; DB writes are in the
      # next phase of the plan)
      mix rho.import_esco /path/to/esco-1.2.1

      # override the library version string
      mix rho.import_esco /path/to/esco-1.2.1 --version 2026.2

  ## Production guard

  When the connected database hostname matches a known production pattern
  (e.g. Neon main), the task refuses to run without `--yes`. This is a
  belt-and-braces guard on top of the recommended branch-first sequence
  documented in `docs/archive/implemented/esco-import-plan.md`.
  """

  alias RhoFrameworks.Import.Esco
  alias RhoFrameworks.Import.Esco.Loader

  @prod_host_patterns [~r/^.*\.neon\.tech$/]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [version: :string, dry_run: :boolean, yes: :boolean]
      )

    dir = List.first(rest)

    unless dir && File.dir?(dir) do
      Mix.shell().error("""
      Usage: mix rho.import_esco <esco-csv-dir> [--version 2026.1] [--dry-run] [--yes]

      <esco-csv-dir> must contain skills_en.csv, skillsHierarchy_en.csv,
      occupations_en.csv, ISCOGroups_en.csv, occupationSkillRelations_en.csv.
      """)

      exit({:shutdown, 1})
    end

    dry_run = Keyword.get(opts, :dry_run, false)
    version = Keyword.get(opts, :version, "2026.1")
    yes = Keyword.get(opts, :yes, false)

    if dry_run do
      run_dry_run(dir, version)
    else
      run_real(dir, version, yes)
    end
  end

  # ── dry-run: parse + print summary, no app start, no DB ─────────────────

  defp run_dry_run(dir, version) do
    Mix.shell().info("[DRY RUN] Parsing ESCO CSVs in #{dir}…")

    parsed = Esco.parse(dir)
    print_summary(parsed, version, dry_run: true)
  end

  # ── real run: parse, bulk-insert via the loader, publish the library.
  # Each step is idempotent so a crash mid-run is recoverable by re-running.

  defp run_real(dir, version, yes) do
    ensure_app_started()
    confirm_prod!(yes)

    Mix.shell().info("Parsing ESCO CSVs in #{dir}…")
    parsed = Esco.parse(dir)
    print_summary(parsed, version, dry_run: false)

    Mix.shell().info("Loading into the DB (system org, library version #{version})…")
    result = Loader.import_all(parsed, version)
    print_load_summary(result)
  end

  defp ensure_app_started do
    Mix.Task.run("app.config", [])
    {:ok, _} = Application.ensure_all_started(:rho_frameworks)
  end

  defp confirm_prod!(true), do: :ok

  defp confirm_prod!(false) do
    case db_hostname() do
      nil ->
        :ok

      host ->
        if Enum.any?(@prod_host_patterns, &Regex.match?(&1, host)) do
          Mix.shell().error("""
          Refusing to write to a production-looking database host (#{host})
          without --yes. Re-run with --yes to confirm, or point DATABASE_URL
          at a Neon branch first.
          """)

          exit({:shutdown, 1})
        end
    end
  end

  defp db_hostname do
    case Application.get_env(:rho_frameworks, RhoFrameworks.Repo)[:url] do
      nil ->
        nil

      url ->
        case URI.parse(url) do
          %URI{host: host} when is_binary(host) -> host
          _ -> nil
        end
    end
  end

  defp print_summary(%Esco.Parsed{stats: stats}, version, dry_run: dry_run) do
    label = if dry_run, do: "[DRY RUN] ", else: ""

    Mix.shell().info("""

    #{label}ESCO parse summary (target version: #{version})
      Skills:         #{stats.skills}
      Role profiles:  #{stats.role_profiles}
      Relations:      #{stats.relations_kept} kept (#{stats.relations_collapsed} collapsed from #{stats.relations_raw} raw)
    """)
  end

  defp print_load_summary(%{
         library: lib,
         skills: skills,
         role_profiles: rps,
         role_skills: rss,
         collapsed_relations: collapsed
       }) do
    Mix.shell().info("""

    Import complete:
      Library:        #{lib.name} (id: #{lib.id}, version: #{lib.version})
                      visibility: #{lib.visibility}, immutable: #{lib.immutable}
      Skills:         #{skills.inserted} inserted, #{skills.skipped} already present (total: #{skills.total})
      Role profiles:  #{rps.inserted} inserted, #{rps.skipped} already present (total: #{rps.total})
      Role skills:    #{rss.inserted} inserted, #{rss.kept} kept after URI resolve, #{rss.dropped} dropped (unmapped URI), #{collapsed} collapsed before insert
    Next: mix rho_frameworks.backfill_embeddings
    """)
  end
end
