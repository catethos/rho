defmodule RhoFrameworks.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field(:email, :string)
    field(:hashed_password, :string, redact: true)
    field(:display_name, :string)
    field(:context, :string)

    field(:password, :string, virtual: true, redact: true)

    has_many(:role_profiles, RhoFrameworks.Frameworks.RoleProfile, foreign_key: :created_by_id)
    has_many(:memberships, RhoFrameworks.Accounts.Membership)
    has_many(:organizations, through: [:memberships, :organization])

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for user registration."
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :password, :display_name])
    |> then(fn changeset ->
      if Keyword.get(opts, :validate, true) do
        changeset
        |> validate_email()
        |> validate_password()
      else
        changeset
      end
    end)
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> update_change(:email, &normalize_email/1)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, RhoFrameworks.Repo)
    |> unique_constraint(:email)
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalize_email(email), do: email

  defp validate_password(changeset) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
    |> hash_password()
  end

  defp hash_password(changeset) do
    password = get_change(changeset, :password)

    if password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc "Changeset for updating profile fields."
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name, :context])
  end

  @doc "Verifies the password against the hashed password."
  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end