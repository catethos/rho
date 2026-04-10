defmodule RhoWeb.DataTable.Schemas do
  @moduledoc """
  Predefined DataTable schemas for known domain tables.
  """

  alias RhoWeb.DataTable.Schema
  alias RhoWeb.DataTable.Schema.Column

  @doc "Skill library editing: structured skills with nested proficiency levels."
  def skill_library do
    %Schema{
      title: "Skill Framework Editor",
      empty_message: "No data — ask the assistant to generate a skill framework",
      group_by: [:category, :cluster],
      children_key: :proficiency_levels,
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
          key: :required_level,
          label: "Required Level",
          type: :number,
          css_class: "dt-col-reqlvl"
        },
        %Column{key: :required, label: "Required", css_class: "dt-col-req"}
      ]
    }
  end
end
