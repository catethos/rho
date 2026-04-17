defmodule RhoFrameworks.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @rand_size 32
  @hash_algorithm :sha256
  @session_validity_in_days 60

  schema "users_tokens" do
    field(:token, :binary)
    field(:context, :string)
    field(:sent_to, :string)

    belongs_to(:user, RhoFrameworks.Accounts.User)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a session token.

  Returns `{raw_token, token_struct}`. The raw token is placed in the user's
  session cookie; the struct (holding only the SHA-256 hash) is persisted.
  A DB compromise therefore does not expose valid session credentials.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed = :crypto.hash(@hash_algorithm, token)
    {token, %__MODULE__{token: hashed, context: "session", user_id: user.id}}
  end

  @doc "Query to find a user by session token (expects the raw cookie token)."
  def verify_session_token_query(token) when is_binary(token) do
    hashed = :crypto.hash(@hash_algorithm, token)

    from(t in __MODULE__,
      where: t.token == ^hashed and t.context == "session",
      where: t.inserted_at > ago(^@session_validity_in_days, "day"),
      join: u in assoc(t, :user),
      select: u
    )
  end

  @doc "Hashes a raw token the same way it is stored. Used by deletion paths."
  def hash_token(token) when is_binary(token) do
    :crypto.hash(@hash_algorithm, token)
  end
end
