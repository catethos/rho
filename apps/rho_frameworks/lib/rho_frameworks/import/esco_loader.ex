defmodule RhoFrameworks.Import.Esco.Loader do
  @moduledoc """
  Persistence layer for the ESCO import.

  `RhoFrameworks.Import.Esco` parses the CSVs into a `%Esco.Parsed{}`. This
  module takes that struct and writes it to the DB using the prefetch +
  `insert_all` returning pattern from
  `Mix.Tasks.Rho.ImportFramework.bulk_upsert_skills_for_import/2`:

    1. one `SELECT ... WHERE library_id = ?` to fetch already-imported rows
       keyed by `metadata->>'esco_uri'`,
    2. filter the parsed list down to URIs we haven't seen,
    3. `Repo.insert_all` with `on_conflict: :nothing` (so re-runs don't crash
       on the unique index) and `returning: [:id, :metadata]` so we can
       harvest the freshly inserted URI→id pairs,
    4. merge prefetched + inserted into a single `%{esco_uri => id}` map
       used by the next phase.

  No transaction wraps the whole thing on purpose. If a step crashes the
  library remains `private` + `mutable` and the next run resumes from where
  it stopped (each `insert_all` is idempotent thanks to the unique index +
  `on_conflict: :nothing`). `publish_library!/1` only runs after every other
  step succeeds.
  """

  import Ecto.Query

  alias RhoFrameworks.Repo
  alias RhoFrameworks.Accounts.Organization
  alias RhoFrameworks.Frameworks.{Library, RoleProfile, RoleSkill, Skill}
  alias RhoFrameworks.Import.Esco

  @system_slug "system"
  @library_name "ESCO Skills & Occupations"
  @library_description "European Skills, Competences, Qualifications and Occupations classification (v1.2.1). Source: https://esco.ec.europa.eu/ — © European Union, CC-BY 4.0."
  @library_metadata %{
    "attribution" => "© European Union, https://esco.ec.europa.eu/",
    "license" => "CC-BY 4.0"
  }
  @library_source_key "esco-1.2.1"

  @skill_chunk 1_000
  @role_profile_chunk 1_000
  @role_skill_chunk 5_000

  @doc """
  Run the full import pipeline. Returns a stats map suitable for the mix
  task's summary print.

  Steps:

    1. `resolve_system_org!/0`
    2. `upsert_library!/2` — private + mutable
    3. `bulk_insert_skills!/2`
    4. `bulk_insert_role_profiles!/2`
    5. `bulk_insert_role_skills!/3`
    6. `publish_library!/1` — flips visibility to "public", immutable to true

  Stops at the first crash; library stays unpublished so users never see a
  partial import.
  """
  @spec import_all(struct(), String.t()) :: map()
  def import_all(%Esco.Parsed{} = parsed, version) when is_binary(version) do
    system_org = resolve_system_org!()
    library = upsert_library!(system_org, version)

    {skill_by_uri, skill_stats} = bulk_insert_skills!(library, parsed.skills)

    {rp_by_uri, role_stats} =
      bulk_insert_role_profiles!(system_org, parsed.role_profiles)

    relation_stats = bulk_insert_role_skills!(rp_by_uri, skill_by_uri, parsed.relations)
    final_library = publish_library!(library)

    %{
      system_org: system_org,
      library: final_library,
      skills: skill_stats,
      role_profiles: role_stats,
      role_skills: relation_stats,
      collapsed_relations: parsed.stats.relations_collapsed
    }
  end

  @doc """
  Fetch the System organization. Created idempotently by the
  `CreateSystemOrganization` migration; this just looks it up.
  """
  @spec resolve_system_org!() :: %Organization{}
  def resolve_system_org! do
    Repo.get_by!(Organization, slug: @system_slug)
  end

  @doc """
  Get-or-insert the ESCO library row. Created `private` + `mutable` so the
  in-progress data isn't visible until `publish_library!/1` flips it after
  every insert step succeeds.
  """
  @spec upsert_library!(%Organization{}, String.t()) :: %Library{}
  def upsert_library!(%Organization{} = system_org, version) when is_binary(version) do
    case Repo.get_by(Library,
           organization_id: system_org.id,
           name: @library_name,
           version: version
         ) do
      nil ->
        %Library{}
        |> Library.changeset(%{
          name: @library_name,
          description: @library_description,
          type: "skill",
          visibility: "private",
          organization_id: system_org.id,
          source_key: @library_source_key,
          version: version,
          immutable: false,
          is_default: false,
          metadata: @library_metadata
        })
        |> Repo.insert!()

      existing ->
        existing
    end
  end

  @doc """
  Insert skill rows in chunks of #{@skill_chunk}, keyed by `esco_uri` for
  resumable re-runs.

  Returns `{skill_by_uri, stats}` where `skill_by_uri` is the merged
  prefetched + inserted map. `stats` is `%{inserted, skipped, total}` —
  `skipped` is the number of URIs already present from a prior run.
  """
  @spec bulk_insert_skills!(%Library{}, [struct()]) :: {map(), map()}
  def bulk_insert_skills!(%Library{} = library, parsed_skills) when is_list(parsed_skills) do
    now = utc_now_seconds()

    existing_map =
      Repo.all(
        from(s in Skill,
          where: s.library_id == ^library.id,
          select: {fragment("?->>'esco_uri'", s.metadata), s.id}
        )
      )
      |> Map.new()

    to_insert =
      parsed_skills
      |> Enum.reject(fn s -> Map.has_key?(existing_map, s.esco_uri) end)

    inserted_pairs =
      to_insert
      |> Stream.chunk_every(@skill_chunk)
      |> Enum.flat_map(fn chunk ->
        rows =
          Enum.map(chunk, fn s ->
            %{
              id: Ecto.UUID.generate(),
              library_id: library.id,
              slug: s.slug,
              name: s.name,
              description: s.description,
              category: s.category,
              cluster: s.cluster,
              status: "published",
              sort_order: nil,
              metadata: s.metadata,
              proficiency_levels: [],
              inserted_at: now,
              updated_at: now
            }
          end)

        {_n, returned} =
          Repo.insert_all(Skill, rows,
            on_conflict: :nothing,
            conflict_target: [:library_id, :slug],
            returning: [:id, :metadata]
          )

        Enum.map(returned, fn r -> {r.metadata["esco_uri"], r.id} end)
      end)

    inserted_map = Map.new(inserted_pairs)
    skill_by_uri = Map.merge(existing_map, inserted_map)

    stats = %{
      inserted: map_size(inserted_map),
      skipped: map_size(existing_map),
      total: map_size(skill_by_uri)
    }

    {skill_by_uri, stats}
  end

  @doc """
  Insert role-profile rows in chunks of #{@role_profile_chunk}.

  Same prefetch + insert_all-with-returning shape as
  `bulk_insert_skills!/2`, keyed by `esco_uri` in metadata. Created with
  `visibility: "public"` and `immutable: true` so other orgs can read them
  immediately once `publish_library!/1` flips the library.
  """
  @spec bulk_insert_role_profiles!(%Organization{}, [struct()]) :: {map(), map()}
  def bulk_insert_role_profiles!(%Organization{} = system_org, parsed_role_profiles)
      when is_list(parsed_role_profiles) do
    now = utc_now_seconds()

    existing_map =
      Repo.all(
        from(rp in RoleProfile,
          where: rp.organization_id == ^system_org.id,
          select: {fragment("?->>'esco_uri'", rp.metadata), rp.id}
        )
      )
      |> Map.new()

    to_insert =
      parsed_role_profiles
      |> Enum.reject(fn rp -> Map.has_key?(existing_map, rp.esco_uri) end)

    inserted_pairs =
      to_insert
      |> Stream.chunk_every(@role_profile_chunk)
      |> Enum.flat_map(fn chunk ->
        rows =
          Enum.map(chunk, fn rp ->
            %{
              id: Ecto.UUID.generate(),
              organization_id: system_org.id,
              created_by_id: nil,
              name: rp.name,
              role_family: rp.role_family,
              description: rp.description,
              purpose: rp.purpose,
              metadata: rp.metadata,
              work_activities: [],
              headcount: 1,
              visibility: "public",
              immutable: true,
              inserted_at: now,
              updated_at: now
            }
          end)

        {_n, returned} =
          Repo.insert_all(RoleProfile, rows,
            on_conflict: :nothing,
            conflict_target: [:organization_id, :name],
            returning: [:id, :metadata]
          )

        Enum.map(returned, fn r -> {r.metadata["esco_uri"], r.id} end)
      end)

    inserted_map = Map.new(inserted_pairs)
    rp_by_uri = Map.merge(existing_map, inserted_map)

    stats = %{
      inserted: map_size(inserted_map),
      skipped: map_size(existing_map),
      total: map_size(rp_by_uri)
    }

    {rp_by_uri, stats}
  end

  @doc """
  Insert role-skill join rows in chunks of #{@role_skill_chunk}. Skips any
  pair where either URI didn't make it into its lookup map (orphan skill
  group references etc.) and counts the drops in the returned stats.
  """
  @spec bulk_insert_role_skills!(map(), map(), [struct()]) :: map()
  def bulk_insert_role_skills!(rp_by_uri, skill_by_uri, relations)
      when is_map(rp_by_uri) and is_map(skill_by_uri) and is_list(relations) do
    now = utc_now_seconds()

    {pending_rows, dropped} =
      Enum.reduce(relations, {[], 0}, fn rel, {rows, drops} ->
        rp_id = Map.get(rp_by_uri, rel.occupation_uri)
        skill_id = Map.get(skill_by_uri, rel.skill_uri)

        cond do
          is_nil(rp_id) or is_nil(skill_id) ->
            {rows, drops + 1}

          true ->
            row = %{
              id: Ecto.UUID.generate(),
              role_profile_id: rp_id,
              skill_id: skill_id,
              required: rel.required,
              min_expected_level: 1,
              weight: 1.0,
              inserted_at: now,
              updated_at: now
            }

            {[row | rows], drops}
        end
      end)

    inserted_count =
      pending_rows
      |> Stream.chunk_every(@role_skill_chunk)
      |> Enum.reduce(0, fn chunk, acc ->
        {n, _} =
          Repo.insert_all(RoleSkill, chunk,
            on_conflict: :nothing,
            conflict_target: [:role_profile_id, :skill_id]
          )

        acc + n
      end)

    %{
      kept: length(pending_rows),
      inserted: inserted_count,
      dropped: dropped
    }
  end

  @doc """
  Flip the library to `public` + `immutable` once every other step has
  succeeded. Idempotent: a library that's already public + immutable is
  returned unchanged so reruns don't reset `published_at`.
  """
  @spec publish_library!(%Library{}) :: %Library{}
  def publish_library!(%Library{visibility: "public", immutable: true} = library), do: library

  def publish_library!(%Library{} = library) do
    library
    |> Library.changeset(%{
      visibility: "public",
      immutable: true,
      published_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()
  end

  defp utc_now_seconds, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
