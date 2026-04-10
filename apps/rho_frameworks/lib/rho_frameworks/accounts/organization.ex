defmodule RhoFrameworks.Accounts.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "organizations" do
    field(:name, :string)
    field(:slug, :string)
    field(:personal, :boolean, default: false)
    field(:context, :string)

    has_many(:memberships, RhoFrameworks.Accounts.Membership)
    has_many(:users, through: [:memberships, :user])
    has_many(:libraries, RhoFrameworks.Frameworks.Library)
    has_many(:role_profiles, RhoFrameworks.Frameworks.RoleProfile)

    timestamps(type: :utc_datetime)
  end

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :slug, :personal, :context])
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: 100)
    |> validate_length(:slug, max: 60)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/,
      message: "must be lowercase alphanumeric with hyphens, no leading/trailing hyphens"
    )
    |> unique_constraint(:slug)
  end
end
