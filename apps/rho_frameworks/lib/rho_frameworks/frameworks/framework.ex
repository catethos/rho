defmodule RhoFrameworks.Frameworks.Framework do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "frameworks" do
    field(:name, :string)
    field(:description, :string)
    field(:metadata, :map, default: %{})

    belongs_to(:user, RhoFrameworks.Accounts.User)
    has_many(:skills, RhoFrameworks.Frameworks.Skill)

    timestamps(type: :utc_datetime)
  end

  def changeset(framework, attrs) do
    framework
    |> cast(attrs, [:name, :description, :metadata, :user_id])
    |> validate_required([:name, :user_id])
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint([:user_id, :name],
      name: :frameworks_user_id_name_index,
      message: "a framework with this name already exists"
    )
  end
end
