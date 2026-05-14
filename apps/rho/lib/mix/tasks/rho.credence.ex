defmodule Mix.Tasks.Rho.Credence do
  @moduledoc """
  Run Credence semantic lint checks over Elixir source files.

  This task reports issues only; it never rewrites source files.

      mix rho.credence
      mix rho.credence apps/rho/lib/rho/runner.ex
      mix rho.credence --full apps/rho/lib/rho/trace/analyzer.ex
      mix rho.credence --all-rules
      mix rho.credence --max-issues 50
      mix rho.credence --no-exit

  By default, this runs Credence's AST-level pattern phase with the repo's
  curated gate rules. Pass `--all-rules` to include Credence's advisory
  quadratic/nested-enum rules, which are useful for hotspot discovery but too
  noisy as a merge gate.

  Pass `--full`
  to run Credence's full syntax + semantic + pattern pipeline for targeted
  files. The full pipeline compiles source strings, which can be noisy for
  umbrella-wide scans.
  """

  use Mix.Task

  @shortdoc "Run Credence semantic lint checks"

  @default_max_issues 200

  @advisory_pattern_rules [
    Credence.Pattern.NoNestedEnumOnSameEnumerable,
    Credence.Pattern.NoNestedEnumOnSameEnumerableUnfixable,
    Credence.Pattern.NoRepeatedEnumTraversal,
    Credence.Pattern.NoEnumAtInLoop,
    Credence.Pattern.NoEnumAtLoopAccess,
    Credence.Pattern.NoStringConcatInLoop,
    Credence.Pattern.NoStringConcatInLoopComplex,
    Credence.Pattern.NoListAppendInLoop
  ]

  @default_patterns [
    "mix.exs",
    "config/**/*.exs",
    "apps/**/*.ex",
    "apps/**/*.exs",
    "priv/**/*.exs"
  ]

  @switches [all_rules: :boolean, full: :boolean, max_issues: :integer, no_exit: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, paths, invalid} = OptionParser.parse(args, switches: @switches)
    analyzer = analyzer_module(opts)

    unless Code.ensure_loaded?(analyzer) do
      Mix.raise("""
      Credence is not available.

      Run `mix deps.get`, then try `mix rho.credence` again.
      """)
    end

    if invalid != [] do
      invalid_args = Enum.map_join(invalid, ", ", &elem(&1, 0))
      Mix.raise("Invalid option(s): #{invalid_args}")
    end

    if max_issues(opts) < 0 do
      Mix.raise("--max-issues must be zero or greater")
    end

    files = source_files(paths)

    if files == [] do
      Mix.shell().info("No Elixir source files found.")
    else
      issues_by_file = analyze_files(files, opts)

      issue_count =
        Enum.reduce(issues_by_file, 0, fn {_file, issues}, acc -> acc + length(issues) end)

      print_report(files, issues_by_file, issue_count, opts)

      if issue_count > 0 and not opts[:no_exit] do
        Mix.raise("Credence found #{issue_count} issue(s).")
      end
    end
  end

  defp source_files([]) do
    @default_patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> normalize_files()
  end

  defp source_files(paths) do
    paths
    |> Enum.flat_map(fn path ->
      cond do
        File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.{ex,exs}"))
        wildcard?(path) -> Path.wildcard(path)
        true -> [path]
      end
    end)
    |> normalize_files()
  end

  defp normalize_files(paths) do
    paths
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(&elixir_source?/1)
    |> Enum.reject(&generated_baml_source?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp wildcard?(path), do: String.contains?(path, ["*", "?", "["])

  defp elixir_source?(path), do: String.ends_with?(path, [".ex", ".exs"])

  defp generated_baml_source?(path) do
    String.contains?(path, "/priv/baml_src/dynamic/")
  end

  defp analyzer_module(opts) do
    if opts[:full] do
      Module.concat([Credence])
    else
      Module.concat([Credence, Pattern])
    end
  end

  defp analyze_files(files, opts) do
    files
    |> Enum.map(fn file ->
      issues =
        file
        |> File.read!()
        |> analyze_source(opts)
        |> extract_issues()

      {file, issues}
    end)
    |> Enum.reject(fn {_file, issues} -> issues == [] end)
  end

  defp extract_issues(%{issues: issues}) when is_list(issues), do: issues
  defp extract_issues(issues) when is_list(issues), do: issues
  defp extract_issues(_result), do: []

  defp analyze_source(source, opts) do
    opts
    |> analyzer_module()
    |> apply(:analyze, [source, analyzer_opts(opts)])
  end

  defp analyzer_opts(opts) do
    if opts[:all_rules] do
      []
    else
      [rules: gate_pattern_rules()]
    end
  end

  defp gate_pattern_rules do
    advisory = MapSet.new(@advisory_pattern_rules)
    Enum.reject(Credence.Pattern.default_rules(), &MapSet.member?(advisory, &1))
  end

  defp print_report(files, [], 0, opts) do
    Mix.shell().info("Credence #{mode(opts)} checked #{length(files)} file(s): no issues found.")
  end

  defp print_report(files, issues_by_file, issue_count, opts) do
    max_issues = max_issues(opts)

    Mix.shell().info(
      "Credence #{mode(opts)} checked #{length(files)} file(s): #{issue_count} issue(s) found.\n"
    )

    {rule_counts, file_counts} = summarize(issues_by_file)

    print_summary(rule_counts, file_counts)
    print_details(issues_by_file, issue_count, max_issues)
  end

  defp summarize(issues_by_file) do
    {rule_counts, file_counts} =
      Enum.reduce(issues_by_file, {%{}, []}, fn {file, issues}, {rule_counts, file_counts} ->
        new_rule_counts =
          Enum.reduce(issues, rule_counts, fn issue, counts ->
            Map.update(counts, issue_rule(issue), 1, &(&1 + 1))
          end)

        {new_rule_counts, [{file, length(issues)} | file_counts]}
      end)

    {
      rule_counts |> Enum.sort_by(fn {_rule, count} -> -count end) |> Enum.take(10),
      file_counts |> Enum.sort_by(fn {_file, count} -> -count end) |> Enum.take(10)
    }
  end

  defp print_summary(rule_counts, file_counts) do
    Mix.shell().info("Top rules:")

    Enum.each(rule_counts, fn {rule, count} ->
      Mix.shell().info("  #{count} #{rule}")
    end)

    Mix.shell().info("\nTop files:")

    Enum.each(file_counts, fn {file, count} ->
      Mix.shell().info("  #{count} #{file}")
    end)
  end

  defp issue_rule(issue) do
    issue
    |> issue_data()
    |> field_value([:rule, "rule"])
    |> format_field("unknown_rule")
  end

  defp print_details(_issues_by_file, issue_count, 0) do
    Mix.shell().info("\nDetailed issues omitted (--max-issues 0). Total: #{issue_count}.")
  end

  defp print_details(issues_by_file, issue_count, max_issues) do
    Mix.shell().info("\nFirst #{min(issue_count, max_issues)} issue(s):")

    issues_by_file
    |> Stream.flat_map(fn {file, issues} -> Stream.map(issues, &{file, &1}) end)
    |> Enum.take(max_issues)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {file, issues} ->
      Mix.shell().info(file)

      Enum.each(issues, fn issue ->
        Mix.shell().info("  #{format_issue(issue)}")
      end)

      Mix.shell().info("")
    end)

    remaining = issue_count - max_issues

    if remaining > 0 do
      Mix.shell().info(
        "... #{remaining} more issue(s) omitted. Increase --max-issues to print more."
      )
    end
  end

  defp max_issues(opts), do: Keyword.get(opts, :max_issues, @default_max_issues)

  defp mode(opts), do: if(opts[:full], do: "full", else: "pattern")

  defp format_issue(issue) do
    data = issue_data(issue)
    location = issue_location(data)
    rule = data |> field_value([:rule, "rule"]) |> format_field("unknown_rule")

    message =
      data
      |> field_value([:message, "message"])
      |> format_field("No message")
      |> first_line()

    [location, rule, message]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp issue_data(%_{} = issue), do: Map.from_struct(issue)
  defp issue_data(issue) when is_map(issue), do: issue
  defp issue_data(issue), do: %{message: inspect(issue)}

  defp issue_location(data) do
    meta = field_value(data, [:meta, "meta"]) || %{}

    case field_value(data, [:line, "line", :position, "position"]) ||
           field_value(meta, [:line, "line", :position, "position"]) do
      {line, col} -> "#{line}:#{col}:"
      line when is_integer(line) -> "#{line}:"
      _ -> nil
    end
  end

  defp field_value(data, keys) do
    Enum.find_value(keys, fn key -> Map.get(data, key) end)
  end

  defp format_field(value, default) when value in [nil, ""], do: default
  defp format_field(value, _default) when is_atom(value), do: inspect(value)
  defp format_field(value, _default) when is_binary(value), do: value
  defp format_field(value, _default), do: inspect(value)

  defp first_line(message) do
    message
    |> String.trim()
    |> String.split("\n", parts: 2)
    |> hd()
  end
end
