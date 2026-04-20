defmodule RhoWeb.AppLive.SettingsEvents do
  @moduledoc false

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 1, to_form: 2]
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  def handle_event("delete_role", %{"name" => name}, socket) do
    org = socket.assigns.current_organization
    RhoFrameworks.Roles.delete_role_profile(org.id, name)
    profiles = RhoFrameworks.Roles.list_role_profiles(org.id)
    {:noreply, assign(socket, profiles: profiles, role_grouped: group_roles_by_family(profiles))}
  end

  def handle_event("save_org", %{"organization" => params}, socket) do
    org = socket.assigns.current_organization

    case RhoFrameworks.Accounts.update_organization(org, params) do
      {:ok, updated_org} ->
        {:noreply,
         socket
         |> assign(:current_organization, updated_org)
         |> assign(
           :org_changeset,
           to_form(RhoFrameworks.Accounts.change_organization(updated_org))
         )
         |> put_flash(:info, "Organization updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :org_changeset, to_form(changeset))}
    end
  end

  def handle_event("save_profile", %{"user" => params}, socket) do
    user = socket.assigns.current_user

    case RhoFrameworks.Accounts.update_user_profile(user, params) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(
           :user_changeset,
           to_form(RhoFrameworks.Accounts.change_user_profile(updated_user), as: "user")
         )
         |> put_flash(:info, "Profile updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :user_changeset, to_form(changeset, as: "user"))}
    end
  end

  def handle_event("delete_org", _params, socket) do
    org = socket.assigns.current_organization
    membership = socket.assigns.current_membership

    cond do
      !RhoFrameworks.Accounts.Authorization.can?(membership, :manage_org) ->
        {:noreply, put_flash(socket, :error, "Only the owner can delete this organization.")}

      org.personal ->
        {:noreply, put_flash(socket, :error, "Personal organizations cannot be deleted.")}

      true ->
        case RhoFrameworks.Accounts.delete_organization(org) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Organization deleted.")
             |> push_navigate(to: ~p"/")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete organization.")}
        end
    end
  end

  # Private helpers

  defp group_roles_by_family(profiles) do
    profiles
    |> Enum.group_by(& &1.role_family)
    |> Enum.sort_by(fn {family, _} -> family || "" end)
  end
end
