defmodule RhoWeb.Plugs.LoadOrganization do
  import Plug.Conn
  import Phoenix.Controller
  alias RhoFrameworks.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns.current_user
    slug = conn.params["org_slug"] || conn.path_params["org_slug"]

    with org when not is_nil(org) <- Accounts.get_organization_by_slug(slug),
         membership when not is_nil(membership) <- Accounts.get_membership(user.id, org.id) do
      conn
      |> assign(:current_organization, org)
      |> assign(:current_membership, membership)
    else
      _ ->
        conn
        |> put_flash(:error, "Organization not found or access denied.")
        |> redirect(to: "/")
        |> halt()
    end
  end
end
