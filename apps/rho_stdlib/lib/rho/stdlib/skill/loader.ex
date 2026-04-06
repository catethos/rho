defmodule Rho.Stdlib.Skill.Loader do
  @moduledoc """
  Discovers, caches, and renders skills from `SKILL.md` files.

  Skills are discovered from three locations (in priority order):

  1. Project skills: `<workspace>/.agents/skills/<name>/SKILL.md`
  2. Global skills:  `~/.agents/skills/<name>/SKILL.md`
  3. Builtin skills: `priv/skills/<name>/SKILL.md`

  Struct definition and file parsing live on `Rho.Skill`.
  """

  alias Rho.Stdlib.Skill

  @cache_table :rho_skill_cache
  @cache_ttl_seconds 2

  @doc """
  Discovers all skills from project, global, and builtin directories.

  Returns a sorted, deduplicated list of `%Rho.Stdlib.Skill{}` structs.
  Project skills override global skills of the same name, which override builtins.

  Results are cached per workspace path with a 2-second TTL and fingerprint check.
  """
  def discover(workspace_path, opts \\ []) do
    sources = Keyword.get(opts, :sources, [:project, :global, :builtin])

    ensure_cache_table()
    cache_key = {workspace_path, sources}
    now = System.monotonic_time(:second)

    case cache_lookup(cache_key) do
      [{_, skills, _fingerprint, checked_at}] when now - checked_at < @cache_ttl_seconds ->
        skills

      cached ->
        old_fingerprint =
          case cached do
            [{_, _, fp, _}] -> fp
            _ -> nil
          end

        new_fingerprint = compute_fingerprint(workspace_path, sources)

        if new_fingerprint == old_fingerprint do
          [{_, skills, _, _}] = cached
          cache_insert({cache_key, skills, new_fingerprint, now})
          skills
        else
          skills = do_discover(workspace_path, sources)
          cache_insert({cache_key, skills, new_fingerprint, now})
          skills
        end
    end
  end

  defp cache_lookup(key) do
    :ets.lookup(@cache_table, key)
  rescue
    ArgumentError ->
      ensure_cache_table()
      []
  end

  defp cache_insert(record) do
    :ets.insert(@cache_table, record)
  rescue
    ArgumentError ->
      ensure_cache_table()

      try do
        :ets.insert(@cache_table, record)
      rescue
        ArgumentError -> :ok
      end
  end

  @doc """
  Renders a prompt section listing available skills.

  Skills in the `expanded` MapSet have their full body included.
  """
  def render_prompt(skills, expanded \\ MapSet.new()) do
    summary =
      skills
      |> Enum.map(fn s -> "- #{s.name}: #{s.description}" end)
      |> Enum.join("\n")

    expanded_bodies =
      skills
      |> Enum.filter(&MapSet.member?(expanded, &1.name))
      |> Enum.map(fn s -> "\n## Skill: #{s.name}\n\n#{s.body}" end)
      |> Enum.join("\n")

    "<available_skills>\n#{summary}\n</available_skills>#{expanded_bodies}"
  end

  @doc """
  Detects which skills are referenced via `$skill-name` in a prompt string.

  Returns a MapSet of skill names that should be expanded.
  """
  def expanded_hints(prompt, skills) do
    skills
    |> Enum.filter(fn s -> String.contains?(prompt, "$#{s.name}") end)
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  # --- Private ---

  defp do_discover(workspace_path, sources) do
    roots = source_roots(workspace_path, sources)

    roots
    |> Enum.flat_map(fn {root, source} ->
      if File.dir?(root) do
        root
        |> File.ls!()
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(&read_skill(&1, source))
      else
        []
      end
    end)
    |> Enum.uniq_by(&String.downcase(&1.name))
    |> Enum.sort_by(& &1.name)
  end

  @doc "Initialise the skill cache ETS table. Called at application startup."
  def init_cache_table do
    :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ensure_cache_table do
    if :ets.whereis(@cache_table) == :undefined do
      init_cache_table()
    end

    :ok
  end

  defp source_roots(workspace_path, sources) do
    all = %{
      project: {Path.join(workspace_path, ".agents/skills"), "project"},
      global: {Path.expand("~/.agents/skills"), "global"},
      builtin: {Application.app_dir(:rho, "priv/skills"), "builtin"}
    }

    Enum.map(sources, &Map.fetch!(all, &1))
  end

  defp compute_fingerprint(workspace_path, sources) do
    roots = Enum.map(source_roots(workspace_path, sources), fn {path, _source} -> path end)

    roots
    |> Enum.flat_map(fn root ->
      if File.dir?(root) do
        root
        |> File.ls!()
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(fn dir ->
          skill_md = Path.join(dir, "SKILL.md")

          case File.stat(skill_md) do
            {:ok, %{mtime: mtime}} -> [{skill_md, mtime}]
            _ -> []
          end
        end)
      else
        []
      end
    end)
    |> Enum.sort()
  end

  defp read_skill(dir, source) do
    skill_md = Path.join(dir, "SKILL.md")

    if File.exists?(skill_md) do
      case Skill.parse_skill_md(skill_md, source) do
        {:ok, skill} -> [skill]
        {:error, _} -> []
      end
    else
      []
    end
  end
end
