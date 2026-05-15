defmodule RhoFrameworks.Library.Versioning do
  @moduledoc """
  Versioning operations for framework libraries.

  The public API remains on `RhoFrameworks.Library`; this module owns published
  version tags, default-version updates, publish validation, and version diffs.
  """

  import Ecto.Query

  alias RhoFrameworks.Frameworks.{Library, Skill}
  alias RhoFrameworks.Library.Queries
  alias RhoFrameworks.Repo

  @doc "Compute the next version tag for a library: YYYY.N where N increments per year."
  def next_version_tag(org_id, library_name) do
    year = Date.utc_today().year
    pattern = "#{year}.%"

    latest_n =
      from(l in Library,
        where:
          l.organization_id == ^org_id and l.name == ^library_name and like(l.version, ^pattern),
        select: max(fragment("CAST(split_part(?, '.', 2) AS INTEGER)", l.version))
      )
      |> Repo.one()

    "#{year}.#{(latest_n || 0) + 1}"
  end

  @doc """
  Publish the current draft as a versioned immutable snapshot.
  """
  def publish_version(org_id, library_id, version_tag \\ nil, opts \\ []) do
    notes = Keyword.get(opts, :notes)

    with %Library{} = lib <- Queries.get_library(org_id, library_id),
         true <- Library.draft?(lib) || {:error, :already_published, lib},
         version_tag <- version_tag || next_version_tag(org_id, lib.name),
         :ok <- validate_version_unique(org_id, lib.name, version_tag) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      metadata =
        if notes do
          Map.put(lib.metadata || %{}, "publish_notes", notes)
        else
          lib.metadata
        end

      lib
      |> Library.changeset(%{
        version: version_tag,
        published_at: now,
        immutable: true,
        metadata: metadata
      })
      |> Repo.update()
    else
      nil ->
        {:error, :not_found}

      {:error, :already_published, lib} ->
        {:error, :already_published,
         "Library is already published (version: #{lib.version}). Create a new draft to make changes."}

      {:error, _, _} = err ->
        err

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Set a published version as the default for its library name.
  """
  def set_default_version(org_id, library_id) do
    with %Library{} = lib <- Queries.get_library(org_id, library_id),
         true <- Library.published?(lib) || {:error, :not_published} do
      Ecto.Multi.new()
      |> Ecto.Multi.update_all(
        :clear_previous,
        from(l in Library,
          where:
            l.organization_id == ^org_id and l.name == ^lib.name and l.is_default == true and
              l.id != ^lib.id
        ),
        set: [is_default: false]
      )
      |> Ecto.Multi.update(:set_default, Library.changeset(lib, %{is_default: true}))
      |> Repo.transaction()
      |> case do
        {:ok, %{set_default: lib}} -> {:ok, lib}
        {:error, _step, reason, _} -> {:error, reason}
      end
    else
      nil ->
        {:error, :not_found}

      {:error, :not_published} ->
        {:error, :not_published, "Only published versions can be set as default."}
    end
  end

  @doc "Diff two versions of the same library."
  def diff_versions(org_id, library_name, version_a, version_b) do
    lib_a = Queries.resolve_library(org_id, library_name, version_a)
    lib_b = Queries.resolve_library(org_id, library_name, version_b)

    cond do
      is_nil(lib_a) ->
        {:error, :not_found, "Version '#{version_a || "draft"}' not found"}

      is_nil(lib_b) ->
        {:error, :not_found, "Version '#{version_b || "draft"}' not found"}

      true ->
        skills_a = Queries.list_skills(lib_a.id, []) |> Map.new(&{&1.slug, &1})
        skills_b = Queries.list_skills(lib_b.id, []) |> Map.new(&{&1.slug, &1})
        slugs_a = Map.keys(skills_a) |> MapSet.new()
        slugs_b = Map.keys(skills_b) |> MapSet.new()
        added = MapSet.difference(slugs_b, slugs_a) |> Enum.map(&skills_b[&1].name)
        removed = MapSet.difference(slugs_a, slugs_b) |> Enum.map(&skills_a[&1].name)

        modified =
          MapSet.intersection(slugs_a, slugs_b)
          |> Enum.filter(fn slug -> skill_modified?(skills_a[slug], skills_b[slug]) end)
          |> Enum.map(&skills_a[&1].name)

        {:ok,
         %{
           version_a: version_a || "draft",
           version_b: version_b || "draft",
           added: added,
           removed: removed,
           modified: modified,
           unchanged_count: MapSet.size(MapSet.intersection(slugs_a, slugs_b)) - length(modified)
         }}
    end
  end

  defp validate_version_unique(org_id, name, version_tag) do
    case Queries.resolve_library(org_id, name, version_tag) do
      nil ->
        :ok

      _exists ->
        {:error, :version_exists, "Version '#{version_tag}' already exists for '#{name}'."}
    end
  end

  defp skill_modified?(%Skill{} = source, %Skill{} = fork) do
    source.name != fork.name || source.description != fork.description ||
      source.proficiency_levels != fork.proficiency_levels
  end
end
