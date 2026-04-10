defmodule RhoFrameworks.Frameworks.RoleSkill do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "role_skills" do
    field(:min_expected_level, :integer)
    field(:weight, :float, default: 1.0)
    field(:required, :boolean, default: true)

    belongs_to(:role_profile, RhoFrameworks.Frameworks.RoleProfile)
    belongs_to(:skill, RhoFrameworks.Frameworks.Skill)

    timestamps(type: :utc_datetime)
  end

  def changeset(role_skill, attrs) do
    role_skill
    |> cast(attrs, [:min_expected_level, :weight, :required, :role_profile_id, :skill_id])
    |> validate_required([:min_expected_level, :role_profile_id, :skill_id])
    |> validate_number(:min_expected_level, greater_than: 0)
    |> validate_number(:weight, greater_than: 0.0)
    |> unique_constraint([:role_profile_id, :skill_id],
      name: :role_skills_role_profile_id_skill_id_index,
      message: "this skill is already assigned to this role"
    )
  end
end
