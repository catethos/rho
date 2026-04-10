defmodule RhoFrameworks.Accounts.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(owner admin member viewer)

  schema "memberships" do
    field(:role, :string, default: "member")

    belongs_to(:user, RhoFrameworks.Accounts.User)
    belongs_to(:organization, RhoFrameworks.Accounts.Organization)

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :organization_id, :role])
    |> validate_required([:user_id, :organization_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:user_id, :organization_id])
  end

  def roles, do: @roles
end
