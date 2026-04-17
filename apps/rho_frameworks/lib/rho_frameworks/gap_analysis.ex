defmodule RhoFrameworks.GapAnalysis do
  @moduledoc "Gap analysis: compares skill snapshots against role profile requirements."

  alias RhoFrameworks.Repo
  alias RhoFrameworks.Frameworks.RoleProfile

  @type skill_snapshot :: %{String.t() => float()}

  @doc """
  Computes per-skill gaps for one person vs one role profile.

  `skill_snapshot` is a map of `%{skill_id => current_level}`.
  Missing skills return `:unknown`, not zero.
  """
  def individual_gap(skill_snapshot, role_profile_id) when is_binary(role_profile_id) do
    role = Repo.get!(RoleProfile, role_profile_id) |> Repo.preload(role_skills: :skill)
    individual_gap(skill_snapshot, role)
  end

  def individual_gap(skill_snapshot, %RoleProfile{} = role) do
    Enum.map(role.role_skills, fn rs ->
      current = Map.get(skill_snapshot, rs.skill_id, :unknown)

      gap =
        if current == :unknown, do: :unknown, else: rs.min_expected_level - current

      %{
        skill_id: rs.skill_id,
        skill_name: rs.skill.name,
        category: rs.skill.category,
        cluster: rs.skill.cluster,
        required_level: rs.min_expected_level,
        current_level: current,
        gap: gap,
        positive_gap: if(gap == :unknown, do: :unknown, else: max(gap, 0)),
        required: rs.required,
        weight: rs.weight
      }
    end)
  end

  @doc """
  Aggregates gaps for a group of people against a role profile.

  `snapshots_by_person` is a list of `{person_id, skill_snapshot}` tuples.
  """
  def team_gap(snapshots_by_person, role_profile_id) do
    role = Repo.get!(RoleProfile, role_profile_id) |> Repo.preload(role_skills: :skill)

    individual_gaps =
      Enum.map(snapshots_by_person, fn {person_id, snapshot} ->
        {person_id, individual_gap(snapshot, role)}
      end)

    all_entries = Enum.flat_map(individual_gaps, fn {_, gaps} -> gaps end)

    aggregate =
      all_entries
      |> Enum.group_by(& &1.skill_id)
      |> Enum.map(fn {skill_id, entries} ->
        known_entries = Enum.reject(entries, &(&1.current_level == :unknown))
        unknown_count = length(entries) - length(known_entries)

        %{
          skill_id: skill_id,
          skill_name: hd(entries).skill_name,
          required_level: hd(entries).required_level,
          known_count: length(known_entries),
          unknown_count: unknown_count,
          pct_meeting:
            if(known_entries == [],
              do: :unknown,
              else:
                Float.round(
                  Enum.count(known_entries, &(&1.positive_gap == 0)) /
                    length(known_entries) * 100,
                  1
                )
            ),
          avg_positive_gap:
            if(known_entries == [],
              do: :unknown,
              else:
                Float.round(
                  Enum.sum(Enum.map(known_entries, & &1.positive_gap)) / length(known_entries),
                  2
                )
            ),
          weighted_avg_gap:
            if(known_entries == [],
              do: :unknown,
              else: weighted_gap_avg(known_entries)
            )
        }
      end)

    %{individual_gaps: individual_gaps, aggregate: aggregate}
  end

  defp weighted_gap_avg(entries) do
    total_weight = Enum.sum(Enum.map(entries, & &1.weight))

    if total_weight == 0,
      do: 0.0,
      else:
        Float.round(
          Enum.sum(Enum.map(entries, fn e -> e.positive_gap * e.weight end)) / total_weight,
          2
        )
  end
end
