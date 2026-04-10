defmodule RhoFrameworks.Frameworks.Library do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "libraries" do
    field(:name, :string)
    field(:description, :string)
    field(:type, :string, default: "skill")
    field(:immutable, :boolean, default: false)
    field(:source_key, :string)
    field(:metadata, :map, default: %{})

    belongs_to(:organization, RhoFrameworks.Accounts.Organization)
    belongs_to(:derived_from, __MODULE__)
    has_many(:skills, RhoFrameworks.Frameworks.Skill)

    timestamps(type: :utc_datetime)
  end

  def changeset(library, attrs) do
    library
    |> cast(attrs, [
      :name,
      :description,
      :type,
      :immutable,
      :source_key,
      :metadata,
      :organization_id,
      :derived_from_id
    ])
    |> validate_required([:name, :organization_id])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:type, ["skill", "psychometric", "qualification"])
    |> unique_constraint([:organization_id, :name],
      name: :libraries_organization_id_name_index,
      message: "a library with this name already exists in this organization"
    )
  end
end
