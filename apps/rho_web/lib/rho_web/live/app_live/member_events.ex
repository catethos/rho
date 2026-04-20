defmodule RhoWeb.AppLive.MemberEvents do
  @moduledoc false

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  def handle_event("invite", %{"email" => email, "role" => role}, socket) do
    org = socket.assigns.current_organization

    if org.personal do
      {:noreply,
       assign(socket, :invite_error, "Cannot invite members to a personal organization.")}
    else
      case RhoFrameworks.Accounts.add_member(org.id, String.trim(email), role) do
        {:ok, _membership} ->
          members = RhoFrameworks.Accounts.list_members(org.id)

          {:noreply,
           socket
           |> assign(:members, members)
           |> assign(:invite_email, "")
           |> assign(:invite_error, nil)
           |> put_flash(:info, "Member added.")}

        {:error, :user_not_found} ->
          {:noreply, assign(socket, :invite_error, "No user found with that email.")}

        {:error, %Ecto.Changeset{}} ->
          {:noreply,
           assign(socket, :invite_error, "Could not add member. They may already be a member.")}

        {:error, _} ->
          {:noreply, assign(socket, :invite_error, "Could not add member.")}
      end
    end
  end

  def handle_event("change_role", %{"membership_id" => membership_id, "role" => new_role}, socket) do
    case RhoFrameworks.Accounts.update_member_role(membership_id, new_role) do
      {:ok, _} ->
        members = RhoFrameworks.Accounts.list_members(socket.assigns.current_organization.id)
        {:noreply, assign(socket, :members, members)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update role.")}
    end
  end

  def handle_event("remove_member", %{"id" => membership_id}, socket) do
    case RhoFrameworks.Accounts.remove_member(membership_id) do
      {:ok, _} ->
        members = RhoFrameworks.Accounts.list_members(socket.assigns.current_organization.id)

        {:noreply,
         socket
         |> assign(:members, members)
         |> put_flash(:info, "Member removed.")}

      {:error, :cannot_remove_owner} ->
        {:noreply,
         put_flash(socket, :error, "Cannot remove the owner. Transfer ownership first.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to remove member.")}
    end
  end

  def handle_event("transfer_ownership", %{"user-id" => new_owner_id}, socket) do
    org = socket.assigns.current_organization

    case RhoFrameworks.Accounts.transfer_ownership(org.id, new_owner_id) do
      :ok ->
        members = RhoFrameworks.Accounts.list_members(org.id)
        membership = RhoFrameworks.Accounts.get_membership(socket.assigns.current_user.id, org.id)

        {:noreply,
         socket
         |> assign(:members, members)
         |> assign(:current_membership, membership)
         |> assign(:is_owner, false)
         |> assign(
           :can_manage,
           RhoFrameworks.Accounts.Authorization.can?(membership, :manage_members)
         )
         |> put_flash(:info, "Ownership transferred.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to transfer ownership.")}
    end
  end
end
