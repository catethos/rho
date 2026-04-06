defmodule RhoFrameworks.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @session_validity_in_days 60

  schema "users_tokens" do
    field(:token, :binary)
    field(:context, :string)
    field(:sent_to, :string)

    belongs_to(:user, RhoFrameworks.Accounts.User)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Generates a session token."
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(32)
    {token, %__MODULE__{token: token, context: "session", user_id: user.id}}
  end

  @doc "Query to find a user by session token."
  def verify_session_token_query(token) do
    from(t in __MODULE__,
      where: t.token == ^token and t.context == "session",
      where: t.inserted_at > ago(^@session_validity_in_days, "day"),
      join: u in assoc(t, :user),
      select: u
    )
  end
end
