defmodule Rho.SkillStore.FrameworkRow do
  use Ecto.Schema
  import Ecto.Changeset

  schema "framework_rows" do
    field(:role, :string, default: "")
    field(:category, :string, default: "")
    field(:cluster, :string, default: "")
    field(:skill_name, :string)
    field(:skill_description, :string, default: "")
    field(:level, :integer, default: 0)
    field(:level_name, :string, default: "")
    field(:level_description, :string, default: "")
    field(:skill_code, :string, default: "")

    belongs_to(:framework, Rho.SkillStore.Framework)

    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :framework_id,
      :role,
      :category,
      :cluster,
      :skill_name,
      :skill_description,
      :level,
      :level_name,
      :level_description,
      :skill_code
    ])
    |> validate_required([:framework_id, :skill_name])
    |> foreign_key_constraint(:framework_id)
  end
end
