defmodule RhoFrameworks.Import.Esco do
  @moduledoc """
  Pure parsing/transform layer for the ESCO v1.2.1 classification CSV bundle.

  No DB writes happen here. The `parse/1` entry point streams the four CSV
  files we use, joins them in memory, dedupes the relation list, and returns
  a `Parsed` struct ready for either:

    * a dry-run summary print (`mix rho.import_esco --dry-run`), or
    * the bulk-insert routine in the Mix task.

  ## CSV files consumed

  | File                                    | Purpose                            |
  |-----------------------------------------|------------------------------------|
  | `skills_en.csv`                         | Skill rows (filter `KnowledgeSkillCompetence`) |
  | `skillsHierarchy_en.csv`                | URI → L1/L2/L3 lookup for category/cluster |
  | `occupations_en.csv`                    | Role profile rows                  |
  | `ISCOGroups_en.csv`                     | ISCO code → label for role_family  |
  | `occupationSkillRelations_en.csv`       | Role↔skill links (essential/optional) |

  Streaming uses `NimbleCSV.RFC4180`, which handles ESCO's quoted multi-line
  `altLabels`, `description`, and `scopeNote` cells correctly.

  ## Slug strategy

  `slug = "<slugify(preferredLabel)>-<last 6 chars of URI>"` — keeps the ~200
  ESCO skills that share `preferredLabel` distinct under the
  `(library_id, slug)` unique index.

  ## Category fallback

  `skills.category` is `NOT NULL`. When the hierarchy join misses (orphan
  URI), we fall back to `reuseLevel` and finally to `"Uncategorized"` so the
  insert never blows up on the constraint.

  ## Relation dedup

  ESCO sometimes lists the same `(occupation_uri, skill_uri)` pair more than
  once with different `relationType` (essential vs optional). We collapse
  duplicates upfront, preferring `essential`, so the resulting `required`
  flag is deterministic regardless of `insert_all` ordering.
  """

  alias NimbleCSV.RFC4180, as: CSV

  defmodule Skill do
    @moduledoc false
    @enforce_keys [:esco_uri, :name, :slug, :category, :description, :metadata]
    defstruct [
      :esco_uri,
      :name,
      :slug,
      :category,
      :cluster,
      :description,
      :metadata
    ]
  end

  defmodule RoleProfile do
    @moduledoc false
    @enforce_keys [:esco_uri, :name, :description, :metadata]
    defstruct [
      :esco_uri,
      :name,
      :role_family,
      :description,
      :purpose,
      :metadata
    ]
  end

  defmodule Relation do
    @moduledoc false
    @enforce_keys [:occupation_uri, :skill_uri, :required]
    defstruct [:occupation_uri, :skill_uri, :required]
  end

  defmodule Parsed do
    @moduledoc false
    @enforce_keys [:skills, :role_profiles, :relations, :stats]
    defstruct [:skills, :role_profiles, :relations, :stats]
  end

  @type stats :: %{
          skills: non_neg_integer(),
          role_profiles: non_neg_integer(),
          relations_raw: non_neg_integer(),
          relations_collapsed: non_neg_integer(),
          relations_kept: non_neg_integer()
        }

  @doc """
  Parse the four CSVs in `dir` and return a `%Parsed{}` with everything the
  importer needs. Pure — no DB writes, no `Mix.shell` calls.
  """
  @spec parse(Path.t()) :: %Parsed{}
  def parse(dir) when is_binary(dir) do
    hierarchy = parse_hierarchy(Path.join(dir, "skillsHierarchy_en.csv"))
    isco = parse_isco_groups(Path.join(dir, "ISCOGroups_en.csv"))

    skills =
      Path.join(dir, "skills_en.csv")
      |> parse_skills(hierarchy)

    role_profiles =
      Path.join(dir, "occupations_en.csv")
      |> parse_occupations(isco)

    {relations, raw_count} =
      Path.join(dir, "occupationSkillRelations_en.csv")
      |> parse_relations()

    stats = %{
      skills: length(skills),
      role_profiles: length(role_profiles),
      relations_raw: raw_count,
      relations_collapsed: raw_count - length(relations),
      relations_kept: length(relations)
    }

    %Parsed{
      skills: skills,
      role_profiles: role_profiles,
      relations: relations,
      stats: stats
    }
  end

  # ── skillsHierarchy_en.csv ──────────────────────────────────────────────
  #
  # ESCO ships hierarchy as a denormalized walk: each row carries
  # Level 0/1/2/3 URI + preferredTerm columns. We only need URI → {L1, L2,
  # L3 preferred terms}. Build a single map keyed by every URI that appears
  # at any level, with the *deepest* enclosing labels.

  @doc false
  @spec parse_hierarchy(Path.t()) :: %{
          optional(String.t()) => %{
            optional(:level_1) => String.t(),
            optional(:level_2) => String.t(),
            optional(:level_3) => String.t(),
            optional(:level_3_uri) => String.t()
          }
        }
  def parse_hierarchy(path) do
    {headers, rows} = read_csv(path)

    idx = column_indexes(headers)
    l0_uri = Map.get(idx, "level 0 uri")
    l1_uri = Map.get(idx, "level 1 uri")
    l2_uri = Map.get(idx, "level 2 uri")
    l3_uri = Map.get(idx, "level 3 uri")
    l1_label = Map.get(idx, "level 1 preferred term")
    l2_label = Map.get(idx, "level 2 preferred term")
    l3_label = Map.get(idx, "level 3 preferred term")

    Enum.reduce(rows, %{}, fn row, acc ->
      l1u = at(row, l1_uri)
      l2u = at(row, l2_uri)
      l3u = at(row, l3_uri)
      l1l = at(row, l1_label)
      l2l = at(row, l2_label)
      l3l = at(row, l3_label)

      labels =
        %{}
        |> put_if(:level_1, l1l)
        |> put_if(:level_2, l2l)
        |> put_if(:level_3, l3l)
        |> put_if(:level_3_uri, l3u)

      [at(row, l0_uri), l1u, l2u, l3u]
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.reduce(acc, fn uri, acc -> Map.put_new(acc, uri, labels) end)
    end)
  end

  # ── ISCOGroups_en.csv ───────────────────────────────────────────────────

  @doc false
  @spec parse_isco_groups(Path.t()) :: %{optional(String.t()) => String.t()}
  def parse_isco_groups(path) do
    {headers, rows} = read_csv(path)
    idx = column_indexes(headers)
    code_idx = Map.get(idx, "code")
    label_idx = Map.get(idx, "preferredlabel")

    rows
    |> Enum.map(fn row -> {at(row, code_idx), at(row, label_idx)} end)
    |> Enum.reject(fn {c, l} -> blank?(c) or blank?(l) end)
    |> Map.new()
  end

  # ── skills_en.csv ───────────────────────────────────────────────────────
  #
  # Filter to `conceptType == "KnowledgeSkillCompetence"` — drops the
  # SkillGroup nodes that share the file. Join hierarchy to build
  # `category` (L1) / `cluster` (L2). Fall back to `reuseLevel` /
  # `"Uncategorized"` so the NOT NULL `category` constraint never trips.

  @doc false
  @spec parse_skills(Path.t(), map()) :: [%Skill{}]
  def parse_skills(path, hierarchy) do
    {headers, rows} = read_csv(path)
    idx = column_indexes(headers)

    type_idx = Map.get(idx, "concepttype")
    uri_idx = Map.get(idx, "concepturi")
    label_idx = Map.get(idx, "preferredlabel")
    desc_idx = Map.get(idx, "description")
    skill_type_idx = Map.get(idx, "skilltype")
    reuse_level_idx = Map.get(idx, "reuselevel")
    alt_idx = Map.get(idx, "altlabels")

    rows
    |> Enum.filter(fn row -> at(row, type_idx) == "KnowledgeSkillCompetence" end)
    |> Enum.map(fn row ->
      uri = at(row, uri_idx)
      name = at(row, label_idx)
      reuse = at(row, reuse_level_idx)
      hierarchy_entry = Map.get(hierarchy, uri, %{})

      category =
        Map.get(hierarchy_entry, :level_1) ||
          presence(reuse) ||
          "Uncategorized"

      cluster = Map.get(hierarchy_entry, :level_2)

      metadata = %{
        "esco_uri" => uri,
        "skill_type" => presence(at(row, skill_type_idx)),
        "reuse_level" => presence(reuse),
        "alt_labels" => parse_alt_labels(at(row, alt_idx)),
        "level_3_uri" => Map.get(hierarchy_entry, :level_3_uri),
        "source" => "ESCO v1.2.1"
      }

      %Skill{
        esco_uri: uri,
        name: name,
        slug: build_slug(name, uri),
        category: category,
        cluster: cluster,
        description: presence(at(row, desc_idx)),
        metadata: metadata
      }
    end)
    |> Enum.reject(fn s -> blank?(s.esco_uri) or blank?(s.name) end)
  end

  # ── occupations_en.csv ──────────────────────────────────────────────────

  @doc false
  @spec parse_occupations(Path.t(), map()) :: [%RoleProfile{}]
  def parse_occupations(path, isco) do
    {headers, rows} = read_csv(path)
    idx = column_indexes(headers)

    type_idx = Map.get(idx, "concepttype")
    uri_idx = Map.get(idx, "concepturi")
    label_idx = Map.get(idx, "preferredlabel")
    desc_idx = Map.get(idx, "description")
    isco_idx = Map.get(idx, "iscogroup")
    alt_idx = Map.get(idx, "altlabels")
    note_idx = Map.get(idx, "regulatedprofessionnote")

    rows
    |> Enum.filter(fn row ->
      # `Occupation` rows only — the file may also include occupation groups
      # depending on the dump variant. Be defensive.
      type = at(row, type_idx)
      is_nil(type) or type == "" or type == "Occupation"
    end)
    |> Enum.map(fn row ->
      uri = at(row, uri_idx)
      name = at(row, label_idx)
      isco_code = presence(at(row, isco_idx))
      isco_label = isco_code && Map.get(isco, isco_code)

      metadata = %{
        "esco_uri" => uri,
        "isco_code" => isco_code,
        "isco_label" => isco_label,
        "alt_labels" => parse_alt_labels(at(row, alt_idx)),
        "regulated_profession_note" => presence(at(row, note_idx)),
        "source" => "ESCO v1.2.1"
      }

      %RoleProfile{
        esco_uri: uri,
        name: name,
        role_family: isco_label,
        description: presence(at(row, desc_idx)),
        purpose: nil,
        metadata: metadata
      }
    end)
    |> Enum.reject(fn r -> blank?(r.esco_uri) or blank?(r.name) end)
  end

  # ── occupationSkillRelations_en.csv ─────────────────────────────────────
  #
  # Returns `{collapsed_relations, raw_row_count}` so the caller can report
  # how many duplicates were merged.

  @doc false
  @spec parse_relations(Path.t()) :: {[%Relation{}], non_neg_integer()}
  def parse_relations(path) do
    {headers, rows} = read_csv(path)
    idx = column_indexes(headers)

    occ_idx = Map.get(idx, "occupationuri")
    rel_idx = Map.get(idx, "relationtype")
    skill_idx = Map.get(idx, "skilluri")

    raw =
      rows
      |> Enum.map(fn row ->
        %Relation{
          occupation_uri: at(row, occ_idx),
          skill_uri: at(row, skill_idx),
          required: at(row, rel_idx) == "essential"
        }
      end)
      |> Enum.reject(fn r -> blank?(r.occupation_uri) or blank?(r.skill_uri) end)

    collapsed =
      raw
      |> Enum.group_by(fn r -> {r.occupation_uri, r.skill_uri} end)
      |> Enum.map(fn {_k, group} ->
        # `essential` wins. If no row in the group is essential, we keep
        # the head — equivalent to "first wins" (any non-essential row
        # would be `required: false`).
        Enum.find(group, hd(group), & &1.required)
      end)

    {collapsed, length(raw)}
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  @doc """
  Build the unique skill slug: `<slugified-name>-<last 6 chars of URI>`.
  """
  @spec build_slug(String.t(), String.t()) :: String.t()
  def build_slug(name, uri) do
    base = slugify(name)
    suffix = uri |> to_string() |> String.slice(-6, 6) |> String.downcase()
    "#{base}-#{suffix}"
  end

  @doc false
  def slugify(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # ESCO `altLabels` cells separate variants by `\n`. Some are blank.
  defp parse_alt_labels(nil), do: []
  defp parse_alt_labels(""), do: []

  defp parse_alt_labels(s) when is_binary(s) do
    s
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp read_csv(path) do
    [headers | rows] =
      path
      |> File.stream!(read_ahead: 100_000)
      |> CSV.parse_stream(skip_headers: false)
      |> Enum.to_list()

    {headers, rows}
  end

  defp column_indexes(headers) do
    headers
    |> Enum.with_index()
    |> Enum.map(fn {h, i} -> {String.downcase(String.trim(h)), i} end)
    |> Map.new()
  end

  defp at(_row, nil), do: nil

  defp at(row, idx) when is_integer(idx) do
    case Enum.at(row, idx) do
      nil -> nil
      v when is_binary(v) -> String.trim(v)
      v -> v
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp presence(v), do: v

  defp put_if(map, _k, v) when v in [nil, ""], do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)
end
