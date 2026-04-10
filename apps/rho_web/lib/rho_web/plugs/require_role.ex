defmodule RhoWeb.Plugs.RequireRole do
  import Plug.Conn
  import Phoenix.Controller
  alias RhoFrameworks.Accounts.Authorization

  def init(opts), do: Keyword.fetch!(opts, :minimum)

  def call(conn, minimum_role) do
    if Authorization.role_at_least?(conn.assigns.current_membership.role, minimum_role) do
      conn
    else
      conn
      |> put_flash(:error, "You don't have permission to do that.")
      |> redirect(to: "/")
      |> halt()
    end
  end
end
