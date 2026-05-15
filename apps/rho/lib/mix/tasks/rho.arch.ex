defmodule Mix.Tasks.Rho.Arch do
  @moduledoc """
  Run lightweight architecture guardrails.

  The first version intentionally keeps hard failures narrow and high
  confidence. Advisory checks print warnings so the team can make existing debt
  visible without blocking unrelated work.

      mix rho.arch
      mix rho.arch apps/rho/lib/rho/runner.ex
      mix rho.arch apps/rho/lib apps/rho_web/lib
  """

  use Mix.Task

  @shortdoc "Run Rho architecture guardrails"

  @default_patterns [
    "mix.exs",
    "apps/**/*.ex",
    "apps/**/*.exs",
    "config/**/*.exs"
  ]

  @max_module_lines 1_500

  @forbidden_refs [
    %{
      root: "apps/rho/lib",
      pattern: ~r/\bRhoWeb\b/,
      message: "core runtime must not reference RhoWeb"
    },
    %{
      root: "apps/rho/lib",
      pattern: ~r/\bRhoFrameworks\.Repo\b/,
      message: "core runtime must not reference RhoFrameworks.Repo"
    },
    %{
      root: "apps/rho_baml/lib",
      pattern: ~r/\bRhoWeb\b/,
      message: "rho_baml must not reference RhoWeb"
    },
    %{
      root: "apps/rho_python/lib",
      pattern: ~r/\bRhoWeb\b/,
      message: "rho_python must not reference RhoWeb"
    },
    %{
      root: "apps/rho_embeddings/lib",
      pattern: ~r/\bRhoWeb\b/,
      message: "rho_embeddings must not reference RhoWeb"
    }
  ]

  @known_tool_names [
    "add_rows",
    "delete_rows",
    "describe_table",
    "edit_row",
    "get_table",
    "list_tables",
    "query_table",
    "replace_all",
    "update_cells"
  ]

  @impl Mix.Task
  def run(args) do
    files = source_files(args)
    results = Enum.map(files, &check_file/1)
    errors = results |> Enum.flat_map(& &1.errors)
    warnings = results |> Enum.flat_map(& &1.warnings)

    print_report(files, errors, warnings)

    if errors != [] do
      Mix.raise("rho.arch found #{length(errors)} architecture error(s).")
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
    |> Enum.reject(&generated_source?/1)
    |> Enum.reject(&self_guardrail_file?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp wildcard?(path), do: String.contains?(path, ["*", "?", "["])

  defp elixir_source?(path), do: String.ends_with?(path, [".ex", ".exs"])

  defp generated_source?(path) do
    String.contains?(path, [
      "/_build/",
      "/deps/",
      "/priv/baml_src/dynamic/"
    ])
  end

  defp check_file(file) do
    source = File.read!(file)

    %{
      errors: forbidden_ref_errors(file, source),
      warnings: module_size_warnings(file, source) ++ prompt_duplication_warnings(file, source)
    }
  end

  defp forbidden_ref_errors(file, source) do
    if self_guardrail_file?(file) do
      []
    else
      forbidden_ref_errors_for_source(file, source)
    end
  end

  defp forbidden_ref_errors_for_source(file, source) do
    @forbidden_refs
    |> Enum.filter(fn rule -> in_root?(file, rule.root) end)
    |> Enum.flat_map(fn rule ->
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _line_no} -> line =~ rule.pattern end)
      |> Enum.map(fn {_line, line_no} ->
        %{file: file, line: line_no, severity: :error, message: rule.message}
      end)
    end)
  end

  defp self_guardrail_file?(file) do
    String.ends_with?(file, "apps/rho/lib/mix/tasks/rho.arch.ex")
  end

  defp in_root?(file, root), do: file == root or String.starts_with?(file, root <> "/")

  defp module_size_warnings(file, source) do
    line_count = source |> String.split("\n") |> length()

    if line_count > @max_module_lines and not generated_source?(file) do
      [
        %{
          file: file,
          line: 1,
          severity: :warning,
          message: "module has #{line_count} lines; consider extracting by ownership"
        }
      ]
    else
      []
    end
  end

  defp prompt_duplication_warnings(file, source) do
    if String.contains?(source, "prompt_sections") do
      source
      |> paragraphs()
      |> Enum.filter(fn {paragraph, _line_no} -> prompt_duplication_paragraph?(paragraph) end)
      |> Enum.map(fn {_paragraph, line_no} ->
        %{
          file: file,
          line: line_no,
          severity: :warning,
          message: "prompt section may duplicate tool/parameter documentation"
        }
      end)
    else
      []
    end
  end

  defp paragraphs(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.chunk_by(fn {line, _line_no} -> String.trim(line) == "" end)
    |> Enum.reject(fn chunk -> chunk_blank?(chunk) end)
    |> Enum.map(fn chunk ->
      {Enum.map_join(chunk, "\n", &elem(&1, 0)), chunk |> hd() |> elem(1)}
    end)
  end

  defp chunk_blank?([{line, _line_no} | _]), do: String.trim(line) == ""

  defp prompt_duplication_paragraph?(paragraph) do
    paragraph = String.downcase(paragraph)
    has_prompt_section? = String.contains?(paragraph, "prompt_sections")
    has_schema_phrase? = String.contains?(paragraph, ["tool", "parameter"])
    has_known_tool? = Enum.any?(@known_tool_names, &String.contains?(paragraph, &1))

    has_prompt_section? and has_schema_phrase? and has_known_tool?
  end

  defp print_report(files, [], []) do
    Mix.shell().info("rho.arch checked #{length(files)} file(s): no issues found.")
  end

  defp print_report(files, errors, warnings) do
    Mix.shell().info(
      "rho.arch checked #{length(files)} file(s): " <>
        "#{length(errors)} error(s), #{length(warnings)} warning(s).\n"
    )

    Enum.each(errors, &print_issue/1)
    Enum.each(warnings, &print_issue/1)
  end

  defp print_issue(issue) do
    Mix.shell().info("#{issue.severity}: #{issue.file}:#{issue.line}: #{issue.message}")
  end
end
