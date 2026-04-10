defmodule RhoFrameworks.Frameworks.RoleProfile do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "role_profiles" do
    # Identity
    field(:name, :string)

    # Classification
    field(:role_family, :string)
    field(:seniority_level, :integer)
    field(:seniority_label, :string)

    # Rich role description (all optional)
    field(:description, :string)
    field(:purpose, :string)
    field(:accountabilities, :string)
    field(:success_metrics, :string)
    field(:qualifications, :string)
    field(:reporting_context, :string)

    # Planning
    field(:headcount, :integer, default: 1)
    field(:metadata, :map, default: %{})
    field(:work_activities, {:array, :map}, default: [])

    # Fork lineage
    field(:immutable, :boolean, default: false)
    belongs_to(:source_role_profile, __MODULE__)

    belongs_to(:organization, RhoFrameworks.Accounts.Organization)
    belongs_to(:created_by, RhoFrameworks.Accounts.User)
    has_many(:role_skills, RhoFrameworks.Frameworks.RoleSkill)

    timestamps(type: :utc_datetime)
  end

  def changeset(role_profile, attrs) do
    role_profile
    |> cast(attrs, [
      :name,
      :role_family,
      :seniority_level,
      :seniority_label,
      :description,
      :purpose,
      :accountabilities,
      :success_metrics,
      :qualifications,
      :reporting_context,
      :headcount,
      :metadata,
      :work_activities,
      :immutable,
      :source_role_profile_id,
      :organization_id,
      :created_by_id
    ])
    |> validate_required([:name, :organization_id])
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint([:organization_id, :name],
      name: :role_profiles_organization_id_name_index,
      message: "a role profile with this name already exists"
    )
  end
end
