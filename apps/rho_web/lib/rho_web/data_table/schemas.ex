defmodule RhoWeb.DataTable.Schemas do
  @moduledoc """
  Predefined `RhoWeb.DataTable.Schema` values keyed by a **view key**.

  Web schemas describe *how* a data table renders — column labels,
  groupings, css classes, edit behavior. They are intentionally
  distinct from the stdlib `Rho.Stdlib.DataTable.Schema` structs used
  for storage-side validation.

  ## Resolution

  The LiveView resolves a web schema from:

    1. An explicit `view_key` (atom or string) set on the workspace
       snapshot cache by `EffectDispatcher` when a `Rho.Effect.Table`
       carries `schema_key`.
    2. The current `active_table` name, for future named-table rendering.
    3. A generic fallback for unknown keys.

  `resolve/2` is the single entry point; callers should never branch on
  `String.to_atom/1`. Lookups are via whitelist maps.
  """

  alias RhoWeb.DataTable.Schema
  alias RhoWeb.DataTable.Schema.Column

  @doc """
  Resolve a web schema by view key (atom or string) and/or table name.

  Tries `view_key` first, then `table_name`, then falls back to a
  generic schema. Always returns a `%RhoWeb.DataTable.Schema{}`.
  """
  @spec resolve(atom() | String.t() | nil, String.t() | nil) :: Schema.t()
  def resolve(view_key, table_name \\ nil)

  def resolve(view_key, _table_name) when view_key in [:skill_library, "skill_library"],
    do: skill_library()

  def resolve(view_key, _table_name) when view_key in [:role_profile, "role_profile"],
    do: role_profile()

  def resolve(view_key, _table_name) when view_key in [:combine_conflicts, "combine_conflicts"],
    do: combine_conflicts()

  def resolve(view_key, _table_name) when view_key in [:dedup_preview, "dedup_preview"],
    do: dedup_preview()

  def resolve(view_key, _table_name) when view_key in [:role_candidates, "role_candidates"],
    do: role_candidates()

  def resolve(view_key, _table_name) when view_key in [:taxonomy, "taxonomy"],
    do: taxonomy()

  def resolve(view_key, _table_name) when view_key in [:research_notes, "research_notes"],
    do: research_notes()

  def resolve(nil, table_name) when is_binary(table_name) do
    by_table_name(table_name)
  end

  def resolve(_view_key, table_name) when is_binary(table_name) do
    by_table_name(table_name)
  end

  def resolve(_view_key, _table_name), do: generic()

  defp by_table_name("library:" <> _), do: skill_library()
  defp by_table_name("taxonomy:" <> _), do: taxonomy()
  defp by_table_name("library"), do: skill_library()
  defp by_table_name("role_profile"), do: role_profile()
  defp by_table_name("combine_preview"), do: combine_conflicts()
  defp by_table_name("dedup_preview"), do: dedup_preview()
  defp by_table_name("role_candidates"), do: role_candidates()
  defp by_table_name("research_notes"), do: research_notes()
  defp by_table_name(_), do: generic()

  @doc "Skill library editing: structured skills with nested proficiency levels."
  def skill_library do
    %Schema{
      title: "Skill Framework Editor",
      empty_message: "No data — ask the assistant to generate a skill framework",
      group_by: [:category, :cluster],
      children_key: :proficiency_levels,
      child_key_fields: [:level],
      show_id: false,
      children_display: :panel,
      columns: [
        %Column{key: :category, label: "Category", editable: false, css_class: "dt-col-cat"},
        %Column{key: :cluster, label: "Cluster", editable: false, css_class: "dt-col-cluster"},
        %Column{key: :skill_name, label: "Skill", css_class: "dt-col-skill"},
        %Column{
          key: :skill_description,
          label: "Description",
          type: :textarea,
          css_class: "dt-col-desc"
        }
      ],
      child_columns: [
        %Column{key: :level, label: "Lvl", type: :number, css_class: "dt-col-lvl"},
        %Column{key: :level_name, label: "Level Name", css_class: "dt-col-lvlname"},
        %Column{
          key: :level_description,
          label: "Level Description",
          type: :textarea,
          css_class: "dt-col-lvldesc"
        }
      ]
    }
  end

  @doc "Role profile editing: one row per skill with required level."
  def role_profile do
    %Schema{
      title: "Role Profile Editor",
      empty_message: "No data — load a skill library first",
      group_by: [:category, :cluster],
      columns: [
        %Column{key: :category, label: "Category", editable: false, css_class: "dt-col-cat"},
        %Column{key: :cluster, label: "Cluster", editable: false, css_class: "dt-col-cluster"},
        %Column{key: :skill_name, label: "Skill", editable: false, css_class: "dt-col-skill"},
        %Column{
          key: :skill_description,
          label: "Description",
          type: :textarea,
          css_class: "dt-col-desc"
        },
        %Column{
          key: :required_level,
          label: "Required Level",
          type: :number,
          css_class: "dt-col-reqlvl"
        },
        %Column{key: :required, label: "Required", css_class: "dt-col-req"}
      ]
    }
  end

  @doc "Combine conflicts: side-by-side skill pairs with resolution actions."
  def combine_conflicts do
    %Schema{
      title: "Resolve Conflicts",
      empty_message: "No conflicts — all skills merge cleanly",
      group_by: [],
      show_id: false,
      columns: [
        %Column{
          key: :confidence,
          label: "Match",
          editable: false,
          css_class: "dt-col-confidence"
        },
        %Column{
          key: :skill_a_name,
          label: "Skill A",
          editable: false,
          css_class: "dt-col-skill-a"
        },
        %Column{
          key: :skill_a_description,
          label: "Desc A",
          editable: false,
          css_class: "dt-col-desc-a"
        },
        %Column{
          key: :skill_b_name,
          label: "Skill B",
          editable: false,
          css_class: "dt-col-skill-b"
        },
        %Column{
          key: :skill_b_description,
          label: "Desc B",
          editable: false,
          css_class: "dt-col-desc-b"
        },
        %Column{
          key: :resolution,
          label: "Action",
          editable: false,
          type: :action,
          css_class: "dt-col-action"
        }
      ]
    }
  end

  @doc """
  Within-library duplicate review: cluster + side-by-side skill pairs
  + resolution column. Mirrors `combine_conflicts` shape; the extra
  `cluster` column carries the LLM-summarized theme label so users can
  group rows by topic before reviewing.
  """
  def dedup_preview do
    %Schema{
      title: "Review Duplicates",
      empty_message: "No duplicate candidates — your library is clean",
      group_by: [:cluster],
      show_id: false,
      columns: [
        %Column{
          key: :cluster,
          label: "Cluster",
          editable: false,
          css_class: "dt-col-cluster"
        },
        %Column{
          key: :confidence,
          label: "Match",
          editable: false,
          css_class: "dt-col-confidence"
        },
        %Column{
          key: :skill_a_name,
          label: "Skill A",
          editable: false,
          css_class: "dt-col-skill-a"
        },
        %Column{
          key: :skill_a_description,
          label: "Desc A",
          editable: false,
          css_class: "dt-col-desc-a"
        },
        %Column{
          key: :skill_b_name,
          label: "Skill B",
          editable: false,
          css_class: "dt-col-skill-b"
        },
        %Column{
          key: :skill_b_description,
          label: "Desc B",
          editable: false,
          css_class: "dt-col-desc-b"
        },
        %Column{
          key: :resolution,
          label: "Action",
          editable: false,
          type: :action,
          css_class: "dt-col-action"
        }
      ]
    }
  end

  @doc """
  Candidate-role picker: search results from `analyze_role(find_similar)`,
  grouped by query. The user checks rows via the existing checkbox column;
  downstream tools (`seed_framework_from_roles(from_selected_candidates: true)`,
  `manage_role(action: "clone")`) read the selection and act on the picked
  role_ids.
  """
  def role_candidates do
    %Schema{
      title: "Candidate Roles",
      empty_message: "No candidate roles — try a broader query",
      group_by: [:query],
      show_id: false,
      columns: [
        %Column{key: :rank, label: "#", editable: false, css_class: "dt-col-rank"},
        %Column{key: :role_name, label: "Role", editable: false, css_class: "dt-col-role"},
        %Column{
          key: :role_family,
          label: "Family",
          editable: false,
          css_class: "dt-col-family"
        },
        %Column{
          key: :seniority_label,
          label: "Level",
          editable: false,
          css_class: "dt-col-level"
        },
        %Column{
          key: :skill_count,
          label: "Skills",
          editable: false,
          css_class: "dt-col-skill-count"
        },
        %Column{
          key: :source_libraries,
          label: "Libraries",
          editable: false,
          css_class: "dt-col-family"
        }
      ]
    }
  end

  @doc "Taxonomy draft review: one row per category/cluster before skill generation."
  def taxonomy do
    %Schema{
      title: "Framework Taxonomy",
      empty_message: "No taxonomy yet",
      group_by: [:category],
      show_id: false,
      columns: [
        %Column{key: :category, label: "Category", css_class: "dt-col-cat"},
        %Column{
          key: :category_description,
          label: "Category Description",
          type: :textarea,
          css_class: "dt-col-desc"
        },
        %Column{key: :cluster, label: "Cluster", css_class: "dt-col-cluster"},
        %Column{
          key: :cluster_description,
          label: "Cluster Description",
          type: :textarea,
          css_class: "dt-col-desc"
        },
        %Column{
          key: :target_skill_count,
          label: "Target Skills",
          type: :number,
          css_class: "dt-col-reqlvl"
        },
        %Column{
          key: :transferability,
          label: "Focus",
          css_class: "dt-col-family"
        },
        %Column{
          key: :rationale,
          label: "Rationale",
          type: :textarea,
          css_class: "dt-col-desc"
        }
      ]
    }
  end

  @doc "Research findings collected during framework generation."
  def research_notes do
    %Schema{
      title: "Research Notes",
      empty_message: "No research notes yet",
      group_by: [],
      show_id: false,
      row_layout: :research_notes,
      columns: [
        %Column{
          key: :fact,
          label: "Finding",
          type: :textarea,
          css_class: "dt-col-research-finding"
        },
        %Column{key: :source_title, label: "Source", css_class: "dt-col-research-source"},
        %Column{key: :source, label: "URL", css_class: "dt-col-research-url"},
        %Column{key: :published_date, label: "Published", css_class: "dt-col-research-date"},
        %Column{key: :tag, label: "Tag", css_class: "dt-col-research-tag"},
        %Column{
          key: :relevance,
          label: "Score",
          type: :number,
          css_class: "dt-col-research-score"
        },
        %Column{key: :pinned, label: "Pinned", css_class: "dt-col-research-pinned"}
      ]
    }
  end

  @doc """
  Generic fallback for unknown / dynamic tables (e.g. `"main"`).

  Columns are derived at render time from the first row's keys — this
  schema just carries the title + empty message + an empty columns
  list. The component is expected to infer column headers from rows
  when `columns == []` and `children_key == nil`.
  """
  def generic do
    %Schema{
      title: "Data Table",
      empty_message: "No data yet",
      columns: [],
      group_by: []
    }
  end
end
