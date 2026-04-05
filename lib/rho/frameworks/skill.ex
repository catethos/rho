defmodule Rho.Frameworks.Skill do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "skills" do
    field(:category, :string)
    field(:cluster, :string)
    field(:skill_name, :string)
    field(:skill_description, :string)
    field(:level, :integer)
    field(:level_name, :string)
    field(:level_description, :string)
    field(:sort_order, :integer)

    belongs_to(:framework, Rho.Frameworks.Framework)

    timestamps(type: :utc_datetime)
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [
      :category,
      :cluster,
      :skill_name,
      :skill_description,
      :level,
      :level_name,
      :level_description,
      :sort_order,
      :framework_id
    ])
    |> validate_required([:category, :cluster, :skill_name, :level, :framework_id])
  end
end
