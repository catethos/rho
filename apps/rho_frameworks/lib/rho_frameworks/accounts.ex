defmodule RhoFrameworks.Accounts do
  @moduledoc "User account management context."

  import Ecto.Query
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Accounts.{User, UserToken}

  ## Registration

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  ## Authentication

  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  ## Session tokens

  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  def get_user_by_session_token(token) do
    UserToken.verify_session_token_query(token)
    |> Repo.one()
  end

  def delete_user_session_token(token) do
    from(t in UserToken, where: t.token == ^token and t.context == "session")
    |> Repo.delete_all()

    :ok
  end

  ## Changesets

  def change_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, validate: false)
  end

  ## Lookup

  def get_user!(id), do: Repo.get!(User, id)
end
