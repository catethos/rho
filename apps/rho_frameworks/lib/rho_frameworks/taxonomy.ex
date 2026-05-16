defmodule RhoFrameworks.Taxonomy do
  @moduledoc """
  Pure helpers for taxonomy-first framework generation.

  A taxonomy draft is session-scoped and stored in a named DataTable as one
  row per category/cluster pair. The persisted library shape stays unchanged:
  generated skills still land in `library:<name>`.
  """

  alias RhoFrameworks.MapAccess

  @sizes ~w(compact balanced comprehensive custom inferred)
  @specificities ~w(general industry_specific organization_specific)
  @transferabilities ~w(transferable role_specific mixed)
  @styles ~w(from_brief from_jd from_import from_roles)

  @doc "Named table for a taxonomy draft."
  @spec table_name(String.t()) :: String.t()
  def table_name(name) when is_binary(name), do: "taxonomy:" <> String.trim(name)

  @doc "Library table's canonical generated-skills table."
  @spec library_table_name(String.t()) :: String.t()
  def library_table_name(name), do: RhoFrameworks.Library.Editor.table_name(name)

  @doc """
  Normalize taxonomy preferences from form/tool/flow input.

  Defaults are intentionally product-oriented rather than LLM-oriented:
  balanced size, mixed transferability, and general specificity.
  """
  @spec parse_preferences(map()) :: map()
  def parse_preferences(input) when is_map(input) do
    size = pick_string(input, :taxonomy_size, "balanced", @sizes)

    %{
      taxonomy_size: size,
      category_count: parse_positive_int(MapAccess.get(input, :category_count)),
      clusters_per_category: parse_count_hint(MapAccess.get(input, :clusters_per_category)),
      skills_per_cluster: parse_count_hint(MapAccess.get(input, :skills_per_cluster)),
      strict_counts: truthy?(MapAccess.get(input, :strict_counts)),
      specificity: pick_string(input, :specificity, "general", @specificities),
      transferability: normalize_transferability(MapAccess.get(input, :transferability)),
      generation_style: pick_string(input, :generation_style, "from_brief", @styles)
    }
    |> apply_size_defaults()
  end

  @doc "Flatten a taxonomy result into DataTable rows."
  @spec rows_from_result(map(), map()) :: [map()]
  def rows_from_result(result, preferences) when is_map(result) do
    result
    |> MapAccess.get(:categories)
    |> List.wrap()
    |> Enum.flat_map(fn category ->
      category_name = text(MapAccess.get(category, :name))
      category_description = text(MapAccess.get(category, :description))
      category_rationale = text(MapAccess.get(category, :rationale))

      category
      |> MapAccess.get(:clusters)
      |> List.wrap()
      |> Enum.map(fn cluster ->
        cluster_name = text(MapAccess.get(cluster, :name))

        %{
          id: stable_id(category_name, cluster_name),
          category: category_name,
          category_description: category_description,
          cluster: cluster_name,
          cluster_description: text(MapAccess.get(cluster, :description)),
          target_skill_count: parse_positive_int(MapAccess.get(cluster, :target_skill_count)),
          specificity: preferences.specificity,
          transferability:
            normalize_transferability(
              MapAccess.get(cluster, :transferability) || preferences.transferability
            ),
          rationale: text(MapAccess.get(cluster, :rationale) || category_rationale),
          _source: "agent"
        }
      end)
    end)
    |> Enum.reject(fn row -> blank?(row.category) or blank?(row.cluster) end)
    |> dedupe_rows()
  end

  @doc "Normalize already-stored taxonomy rows."
  @spec normalize_rows([map()], map()) :: [map()]
  def normalize_rows(rows, preferences) when is_list(rows) do
    rows
    |> Enum.map(fn row ->
      category = text(MapAccess.get(row, :category))
      cluster = text(MapAccess.get(row, :cluster))

      %{
        id: MapAccess.get(row, :id) || stable_id(category, cluster),
        category: category,
        category_description: text(MapAccess.get(row, :category_description)),
        cluster: cluster,
        cluster_description: text(MapAccess.get(row, :cluster_description)),
        target_skill_count: parse_positive_int(MapAccess.get(row, :target_skill_count)),
        specificity:
          pick_existing_string(
            MapAccess.get(row, :specificity),
            preferences.specificity,
            @specificities
          ),
        transferability:
          normalize_transferability(
            MapAccess.get(row, :transferability) || preferences.transferability
          ),
        rationale: text(MapAccess.get(row, :rationale)),
        _source: text(MapAccess.get(row, :_source) || "agent")
      }
    end)
    |> Enum.reject(fn row -> blank?(row.category) or blank?(row.cluster) end)
    |> dedupe_rows()
  end

  @doc "Render taxonomy rows for LLM prompt input."
  @spec render_rows([map()]) :: String.t()
  def render_rows(rows) when is_list(rows) do
    rows
    |> Enum.map_join("\n", fn row ->
      count =
        case MapAccess.get(row, :target_skill_count) do
          n when is_integer(n) and n > 0 -> " target=#{n}"
          _ -> ""
        end

      transferability = MapAccess.get(row, :transferability) || "mixed"

      "- #{MapAccess.get(row, :category)} / #{MapAccess.get(row, :cluster)}" <>
        " [#{transferability}#{count}]: " <>
        "#{MapAccess.get(row, :cluster_description) || MapAccess.get(row, :rationale) || ""}"
    end)
    |> case do
      "" -> "(none)"
      rendered -> rendered
    end
  end

  @doc "Return category/cluster pairs approved by the current taxonomy."
  @spec allowed_pairs([map()]) :: MapSet.t({String.t(), String.t()})
  def allowed_pairs(rows) when is_list(rows) do
    MapSet.new(rows, fn row ->
      {normalize_key(MapAccess.get(row, :category)), normalize_key(MapAccess.get(row, :cluster))}
    end)
  end

  @doc "True when a skill row belongs to one of the approved taxonomy pairs."
  @spec allowed_skill?(map(), MapSet.t()) :: boolean()
  def allowed_skill?(skill, allowed) do
    MapSet.member?(
      allowed,
      {normalize_key(MapAccess.get(skill, :category)),
       normalize_key(MapAccess.get(skill, :cluster))}
    )
  end

  defp apply_size_defaults(%{taxonomy_size: "compact"} = prefs) do
    prefs
    |> Map.put(:category_count, prefs.category_count || 3)
    |> Map.put(:clusters_per_category, prefs.clusters_per_category || "2")
    |> Map.put(:skills_per_cluster, prefs.skills_per_cluster || "2-3")
  end

  defp apply_size_defaults(%{taxonomy_size: "balanced"} = prefs) do
    prefs
    |> Map.put(:category_count, prefs.category_count || 4)
    |> Map.put(:clusters_per_category, prefs.clusters_per_category || "2-3")
    |> Map.put(:skills_per_cluster, prefs.skills_per_cluster || "3-4")
  end

  defp apply_size_defaults(%{taxonomy_size: "comprehensive"} = prefs) do
    prefs
    |> Map.put(:category_count, prefs.category_count || 5)
    |> Map.put(:clusters_per_category, prefs.clusters_per_category || "3-4")
    |> Map.put(:skills_per_cluster, prefs.skills_per_cluster || "4-6")
  end

  defp apply_size_defaults(prefs), do: prefs

  defp stable_id(category, cluster) do
    "tax_" <> slug(category) <> "__" <> slug(cluster)
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "blank"
      s -> s
    end
  end

  defp dedupe_rows(rows) do
    rows
    |> Enum.reduce({MapSet.new(), []}, fn row, {seen, acc} ->
      key = {normalize_key(row.category), normalize_key(row.cluster)}

      if MapSet.member?(seen, key) do
        {seen, acc}
      else
        {MapSet.put(seen, key), [row | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp normalize_transferability("role_or_industry_specific"), do: "role_specific"
  defp normalize_transferability("specific"), do: "role_specific"

  defp normalize_transferability(value),
    do: pick_existing_string(value, "mixed", @transferabilities)

  defp pick_string(input, key, default, allowed) do
    input
    |> MapAccess.get(key)
    |> pick_existing_string(default, allowed)
  end

  defp pick_existing_string(value, default, allowed) when is_binary(value) do
    value = String.trim(value)
    if value in allowed, do: value, else: default
  end

  defp pick_existing_string(_value, default, _allowed), do: default

  defp parse_count_hint(nil), do: nil
  defp parse_count_hint(n) when is_integer(n) and n > 0, do: n

  defp parse_count_hint(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      Regex.match?(~r/^\d+$/, trimmed) ->
        parse_positive_int(trimmed)

      Regex.match?(~r/^\d+\s*-\s*\d+$/, trimmed) ->
        String.replace(trimmed, ~r/\s+/, "")

      true ->
        nil
    end
  end

  defp parse_count_hint(_), do: nil

  defp parse_positive_int(nil), do: nil
  defp parse_positive_int(n) when is_integer(n) and n > 0, do: n

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_positive_int(_), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1, "on", "yes"], do: true
  defp truthy?(_), do: false

  defp text(nil), do: nil
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()

  defp normalize_key(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
