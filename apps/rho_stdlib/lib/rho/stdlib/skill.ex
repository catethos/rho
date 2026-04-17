defmodule Rho.Stdlib.Skill do
  @moduledoc """
  Skill data — struct and YAML-frontmatter parser for `SKILL.md` files.

  Discovery, caching, and prompt rendering live on `Rho.Stdlib.Skill.Loader`.
  The plugin wrapper (tools + prompt sections) is `Rho.Stdlib.Skill.Plugin`.
  """

  @enforce_keys [:name, :description, :location, :source]
  defstruct [:name, :description, :location, :source, :body, metadata: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          location: String.t(),
          source: String.t(),
          metadata: map(),
          body: String.t() | nil
        }

  @name_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @doc """
  Parses a single SKILL.md file into a `%Rho.Stdlib.Skill{}`.

  Returns `{:ok, skill}` or `{:error, reason}`.
  """
  def parse_skill_md(path, source) do
    content = File.read!(path)

    case Regex.run(~r/\A---\n(.*?)\n---\n(.*)/s, content) do
      [_, frontmatter, body] ->
        parse_frontmatter(frontmatter, body, path, source)

      _ ->
        {:error, :no_frontmatter}
    end
  end

  defp parse_frontmatter(frontmatter, body, path, source) do
    case YamlElixir.read_from_string(frontmatter) do
      {:ok, meta} ->
        build_skill(meta, body, path, source)

      _ ->
        {:error, :yaml_parse_error}
    end
  end

  defp build_skill(meta, body, path, source) do
    name = meta["name"]
    desc = meta["description"]

    if name && desc && Regex.match?(@name_pattern, name) do
      {:ok,
       %__MODULE__{
         name: name,
         description: desc,
         location: path,
         source: source,
         metadata: meta["metadata"] || %{},
         body: String.trim(body)
       }}
    else
      {:error, :invalid_frontmatter}
    end
  end

  # --- Deprecated delegates ---

  @doc false
  defdelegate discover(workspace_path, opts \\ []), to: Rho.Stdlib.Skill.Loader
  @doc false
  defdelegate render_prompt(skills, expanded \\ MapSet.new()), to: Rho.Stdlib.Skill.Loader
  @doc false
  defdelegate expanded_hints(prompt, skills), to: Rho.Stdlib.Skill.Loader
end
