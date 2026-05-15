defmodule RhoFrameworks.Library.Dedup do
  @moduledoc false

  import Ecto.Query

  alias RhoFrameworks.Frameworks.{DuplicateDismissal, RoleProfile, RoleSkill, Skill}
  alias RhoFrameworks.Library.Queries
  alias RhoFrameworks.Repo

  @semantic_distance_threshold 0.4
  @semantic_high_distance_threshold 0.2
  @semantic_medium_distance_threshold 0.3
  @semantic_knn_top_k 200
  @semantic_jaro_fallback_threshold 0.6

  def find_duplicates(library_id, opts \\ []) do
    depth = Keyword.get(opts, :depth, :standard)
    skills = Queries.list_skills(library_id, [])
    dismissed = list_dismissed_pairs(library_id)
    candidates = find_slug_prefix_overlaps(skills) ++ find_word_overlap_in_category(skills)

    candidates =
      if depth == :deep do
        candidates ++ find_semantic_duplicates(library_id, skills)
      else
        candidates
      end

    candidates
    |> deduplicate_pairs()
    |> reject_dismissed(dismissed)
    |> enrich_with_role_references()
    |> Enum.sort_by(fn c -> -confidence_score(c.confidence) end)
  end

  def dismiss_duplicate(library_id, skill_a_id, skill_b_id) do
    {id_a, id_b} = sorted_pair_key(skill_a_id, skill_b_id)

    %DuplicateDismissal{}
    |> DuplicateDismissal.changeset(%{library_id: library_id, skill_a_id: id_a, skill_b_id: id_b})
    |> Repo.insert(on_conflict: :nothing)
  end

  def consolidation_report(library_id) do
    report_skills = Queries.list_skills(library_id, []) |> Repo.preload(:role_skills)
    duplicates = find_duplicates(library_id)

    {drafts, orphans} = consolidation_buckets(report_skills)

    %{
      total_skills: length(report_skills),
      duplicate_pairs: duplicates,
      drafts: drafts,
      orphans: orphans
    }
  end

  defp consolidation_buckets(report_skills) do
    {drafts, orphans} =
      Enum.reduce(report_skills, {[], []}, fn skill, {drafts, orphans} ->
        next_drafts =
          if skill.status == "draft" do
            [%{id: skill.id, name: skill.name, role_count: length(skill.role_skills)} | drafts]
          else
            drafts
          end

        next_orphans =
          if skill.role_skills == [] do
            [%{id: skill.id, name: skill.name, status: skill.status} | orphans]
          else
            orphans
          end

        {next_drafts, next_orphans}
      end)

    {Enum.sort_by(drafts, &(-&1.role_count)), Enum.reverse(orphans)}
  end

  defp find_semantic_duplicates(_library_id, []), do: []
  defp find_semantic_duplicates(_library_id, [_]), do: []

  defp find_semantic_duplicates(library_id, semantic_rows) do
    embedding_pairs = candidate_pairs_via_embedding_with_distance(library_id)

    fallback_pairs =
      semantic_rows
      |> candidate_pairs_via_jaro_fallback()
      |> Enum.map(fn {a, b} -> {a, b, nil} end)

    (embedding_pairs ++ fallback_pairs)
    |> Enum.uniq_by(fn {a, b, _} -> sorted_pair_key(a.id, b.id) end)
    |> Enum.map(&build_semantic_pair_with_distance/1)
  end

  defp build_semantic_pair_with_distance({a, b, distance}) do
    {sa, sb} =
      if a.id < b.id do
        {a, b}
      else
        {b, a}
      end

    %{
      skill_a: %{id: sa.id, name: sa.name, category: sa.category},
      skill_b: %{id: sb.id, name: sb.name, category: sb.category},
      cosine_distance: distance,
      confidence: confidence_from_distance(distance),
      detection_method: :semantic
    }
  end

  defp confidence_from_distance(nil), do: :low
  defp confidence_from_distance(d) when d < @semantic_high_distance_threshold, do: :high
  defp confidence_from_distance(d) when d < @semantic_medium_distance_threshold, do: :medium
  defp confidence_from_distance(_), do: :low

  defp candidate_pairs_via_embedding_with_distance(library_id) do
    threshold = @semantic_distance_threshold
    top_k = @semantic_knn_top_k

    sql = "SELECT s1.id AS a_id, s2.id AS b_id, s2.dist AS dist
FROM skills s1
CROSS JOIN LATERAL (
  SELECT s.id, (s.embedding <=> s1.embedding) AS dist
  FROM skills s
  WHERE s.library_id = s1.library_id
    AND s.id > s1.id
    AND s.embedding IS NOT NULL
    AND (s.embedding <=> s1.embedding) < $2
  ORDER BY s.embedding <=> s1.embedding
  LIMIT $3
) s2
WHERE s1.library_id = $1
  AND s1.embedding IS NOT NULL
"

    %{rows: db_rows} =
      Repo.query!(sql, [Ecto.UUID.dump!(library_id), threshold, top_k],
        timeout: :timer.minutes(2)
      )

    case db_rows do
      [] ->
        []

      _ ->
        triples =
          Enum.map(db_rows, fn [a_uuid, b_uuid, dist] ->
            {Ecto.UUID.cast!(a_uuid), Ecto.UUID.cast!(b_uuid), dist}
          end)

        ids = triples |> Enum.flat_map(fn {a, b, _} -> [a, b] end) |> Enum.uniq()

        skills_by_id =
          from(s in Skill, where: s.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})

        Enum.map(triples, fn {a_id, b_id, dist} ->
          {Map.fetch!(skills_by_id, a_id), Map.fetch!(skills_by_id, b_id), dist}
        end)
    end
  end

  defp candidate_pairs_via_jaro_fallback(jaro_rows) do
    threshold = @semantic_jaro_fallback_threshold

    jaro_rows
    |> unordered_pairs()
    |> Enum.filter(fn {a, b} ->
      (is_nil(a.embedding) or is_nil(b.embedding)) and
        String.jaro_distance(String.downcase(a.name), String.downcase(b.name)) >= threshold
    end)
  end

  defp enrich_with_role_references(candidates) do
    skill_ids = Enum.flat_map(candidates, fn c -> [c.skill_a.id, c.skill_b.id] end) |> Enum.uniq()

    role_refs =
      from(rs in RoleSkill,
        join: rp in RoleProfile,
        on: rs.role_profile_id == rp.id,
        where: rs.skill_id in ^skill_ids,
        select: {rs.skill_id, rp.name, rs.min_expected_level}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_, name, level} -> {name, level} end)

    Enum.map(candidates, &enrich_candidate(&1, role_refs))
  end

  defp enrich_candidate(candidate, role_refs) do
    refs_a = Map.get(role_refs, candidate.skill_a.id, [])
    refs_b = Map.get(role_refs, candidate.skill_b.id, [])
    role_names_a = Enum.map(refs_a, &elem(&1, 0))
    role_names_b = Enum.map(refs_b, &elem(&1, 0))
    levels_a = Map.new(refs_a)
    levels_b = Map.new(refs_b)
    shared_roles = MapSet.intersection(MapSet.new(role_names_a), MapSet.new(role_names_b))

    level_conflict =
      Enum.any?(shared_roles, fn role ->
        Map.fetch!(levels_a, role) != Map.fetch!(levels_b, role)
      end)

    Map.merge(candidate, %{
      roles_a: role_names_a,
      roles_b: role_names_b,
      level_conflict: level_conflict
    })
  end

  defp list_dismissed_pairs(library_id) do
    from(d in DuplicateDismissal, where: d.library_id == ^library_id)
    |> Repo.all()
    |> Enum.map(fn d -> {d.skill_a_id, d.skill_b_id} end)
    |> MapSet.new()
  end

  defp find_slug_prefix_overlaps(prefix_rows) do
    prefix_rows
    |> Enum.map(fn s -> {s.id, s.slug, s.name, s.category} end)
    |> slug_prefix_overlaps()
  end

  defp slug_prefix_overlaps(slug_rows) do
    slug_rows
    |> unordered_pairs()
    |> Enum.flat_map(fn {{id_a, slug_a, name_a, cat_a}, {id_b, slug_b, name_b, cat_b}} ->
      if shared_prefix_length(slug_a, slug_b) >= 3 do
        {summary_a, summary_b} =
          ordered_skill_summary_pair({id_a, name_a, cat_a}, {id_b, name_b, cat_b})

        [
          %{
            skill_a: summary_a,
            skill_b: summary_b,
            confidence: :high,
            detection_method: :slug_prefix
          }
        ]
      else
        []
      end
    end)
  end

  defp find_word_overlap_in_category(category_rows) do
    by_cat = Enum.group_by(category_rows, & &1.category)

    Enum.flat_map(by_cat, fn {_cat, cat_skills} ->
      cat_skills
      |> unordered_pairs()
      |> Enum.flat_map(fn {a, b} ->
        if jaccard_similarity(a.name, b.name) >= 0.5 do
          {summary_a, summary_b} =
            ordered_skill_summary_pair({a.id, a.name, a.category}, {b.id, b.name, b.category})

          [
            %{
              skill_a: summary_a,
              skill_b: summary_b,
              confidence: :medium,
              detection_method: :word_overlap
            }
          ]
        else
          []
        end
      end)
    end)
  end

  defp ordered_skill_summary_pair({id_a, name_a, cat_a}, {id_b, name_b, cat_b}) do
    summary_a = %{id: id_a, name: name_a, category: cat_a}
    summary_b = %{id: id_b, name: name_b, category: cat_b}

    if id_a < id_b do
      {summary_a, summary_b}
    else
      {summary_b, summary_a}
    end
  end

  defp unordered_pairs(rows) do
    rows |> collect_unordered_pairs([]) |> Enum.reverse()
  end

  defp collect_unordered_pairs([], acc), do: acc
  defp collect_unordered_pairs([_single], acc), do: acc

  defp collect_unordered_pairs([first | rest], acc) do
    next_acc = Enum.reduce(rest, acc, fn item, pairs -> [{first, item} | pairs] end)
    collect_unordered_pairs(rest, next_acc)
  end

  defp shared_prefix_length(a, b) do
    a
    |> String.graphemes()
    |> Enum.zip(String.graphemes(b))
    |> Enum.reduce_while(0, fn {x, y}, acc ->
      if x == y, do: {:cont, acc + 1}, else: {:halt, acc}
    end)
  end

  defp jaccard_similarity(a, b) do
    words_a = a |> String.downcase() |> String.split(~r/\s+/) |> MapSet.new()
    words_b = b |> String.downcase() |> String.split(~r/\s+/) |> MapSet.new()
    inter = MapSet.intersection(words_a, words_b) |> MapSet.size()
    union = MapSet.union(words_a, words_b) |> MapSet.size()

    if union == 0 do
      0.0
    else
      inter / union
    end
  end

  defp deduplicate_pairs(candidates) do
    Enum.uniq_by(candidates, fn c -> sorted_pair_key(c.skill_a.id, c.skill_b.id) end)
  end

  defp reject_dismissed(candidates, dismissed) do
    Enum.reject(candidates, fn c ->
      MapSet.member?(dismissed, sorted_pair_key(c.skill_a.id, c.skill_b.id))
    end)
  end

  defp sorted_pair_key(id_a, id_b) do
    if id_a < id_b do
      {id_a, id_b}
    else
      {id_b, id_a}
    end
  end

  defp confidence_score(:high), do: 3
  defp confidence_score(:medium), do: 2
  defp confidence_score(:low), do: 1
end
