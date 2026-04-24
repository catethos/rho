# Script for populating the database. Run with:
#
#     mix run apps/rho_frameworks/priv/repo/seeds.exs
#
# Or automatically after `mix ecto.setup` / `mix ecto.reset`.

alias RhoFrameworks.Accounts

default_email = "cloverethos@gmail.com"

case Accounts.register_user(%{email: default_email, password: "password123456"}) do
  {:ok, user} ->
    IO.puts("Created user: #{user.email}")

  {:error, changeset} ->
    if Keyword.has_key?(changeset.errors, :email) do
      IO.puts("User #{default_email} already exists, skipping.")
    else
      IO.puts("Failed to create user: #{inspect(changeset.errors)}")
    end
end
