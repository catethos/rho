defmodule RhoFrameworks.DataTableSchemas do
  @moduledoc """
  Declared `Rho.Stdlib.DataTable.Schema` values for frameworks-domain
  tables (`library`, `role_profile`).

  These mirror the shape of the SQLite persistence layer (see
  `RhoFrameworks.Frameworks.Skill` for the `{:array, :map}` embedded
  proficiency levels). Domain tools call `Rho.Stdlib.DataTable.ensure_table/4`
  with one of these schemas before writing rows to a named table.
  """

  alias Rho.Stdlib.DataTable.Schema
  alias Rho.Stdlib.DataTable.Schema.Column

  @doc "Schema for the `\"library\"` table: skills grouped by category/cluster with nested proficiency levels."
  def library_schema do
    %Schema{
      name: "library",
      mode: :strict,
      columns: [
        %Column{name: :category, type: :string, required?: true, doc: "Top-level grouping"},
        %Column{
          name: :cluster,
          type: :string,
          required?: true,
          doc: "Sub-grouping within category"
        },
        %Column{name: :skill_name, type: :string, required?: true, doc: "Skill name"},
        %Column{name: :skill_description, type: :string, required?: false}
      ],
      children_key: :proficiency_levels,
      child_columns: [
        %Column{
          name: :level,
          type: :integer,
          required?: true,
          doc: "0-5 (0 = placeholder)"
        },
        %Column{name: :level_name, type: :string, required?: false},
        %Column{name: :level_description, type: :string, required?: false}
      ],
      key_fields: [:skill_name]
    }
  end

  @doc "Schema for the `\"combine_preview\"` table: conflict pairs for library combining."
  def combine_preview_schema do
    %Schema{
      name: "combine_preview",
      mode: :strict,
      columns: [
        %Column{name: :category, type: :string, required?: false, doc: "Shared category"},
        %Column{name: :confidence, type: :string, required?: true, doc: "high/medium/low"},
        %Column{name: :skill_a_id, type: :string, required?: true},
        %Column{name: :skill_a_name, type: :string, required?: true},
        %Column{name: :skill_a_description, type: :string, required?: false},
        %Column{name: :skill_a_source, type: :string, required?: true},
        %Column{name: :skill_a_levels, type: :integer, required?: false},
        %Column{name: :skill_a_roles, type: :integer, required?: false},
        %Column{name: :skill_b_id, type: :string, required?: true},
        %Column{name: :skill_b_name, type: :string, required?: true},
        %Column{name: :skill_b_description, type: :string, required?: false},
        %Column{name: :skill_b_source, type: :string, required?: true},
        %Column{name: :skill_b_levels, type: :integer, required?: false},
        %Column{name: :skill_b_roles, type: :integer, required?: false},
        %Column{
          name: :resolution,
          type: :string,
          required?: false,
          doc: "merge_a/merge_b/keep_both/unresolved"
        }
      ],
      key_fields: [:skill_a_id, :skill_b_id]
    }
  end

  @doc "Schema for the `\"flow:state\"` table: tracks wizard flow progress."
  def flow_state_schema do
    %Schema{
      name: "flow:state",
      mode: :strict,
      columns: [
        %Column{name: :flow_id, type: :string, required?: true, doc: "Flow type identifier"},
        %Column{
          name: :current_step,
          type: :string,
          required?: true,
          doc: "Current step atom as string"
        },
        %Column{name: :status, type: :string, required?: true, doc: "running/completed/failed"},
        %Column{
          name: :step_results_json,
          type: :string,
          required?: false,
          doc: "JSON-encoded step results"
        },
        %Column{name: :library_id, type: :string, required?: false},
        %Column{name: :table_name, type: :string, required?: false},
        %Column{name: :started_at, type: :string, required?: true},
        %Column{name: :updated_at, type: :string, required?: true}
      ],
      key_fields: [:flow_id]
    }
  end

  @doc "Schema for the `\"role_profile\"` table: one row per required skill with level."
  def role_profile_schema do
    %Schema{
      name: "role_profile",
      mode: :strict,
      columns: [
        %Column{name: :category, type: :string, required?: false},
        %Column{name: :cluster, type: :string, required?: false},
        %Column{name: :skill_name, type: :string, required?: true},
        %Column{name: :skill_description, type: :string, required?: false},
        %Column{name: :required_level, type: :integer, required?: true},
        %Column{name: :required, type: :boolean, required?: true}
      ],
      key_fields: [:skill_name]
    }
  end
end
