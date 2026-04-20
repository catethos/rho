defmodule RhoWeb.OrgMembersLive do
  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  import RhoWeb.CoreComponents

  alias RhoFrameworks.Accounts
  alias RhoFrameworks.Accounts.Authorization

  @impl true
  def mount(_params, _session, socket) do
    membership = socket.assigns.current_membership
    can_manage = Authorization.can?(membership, :manage_members)
    is_owner = Authorization.can?(membership, :manage_org)

    members =
      if connected?(socket),
        do: Accounts.list_members(socket.assigns.current_organization.id),
        else: []

    {:ok,
     socket
     |> assign(:members, members)
     |> assign(:can_manage, can_manage)
     |> assign(:is_owner, is_owner)
     |> assign(:invite_email, "")
     |> assign(:invite_role, "member")
     |> assign(:invite_error, nil)
     |> assign(:active_page, :members)}
  end

  @impl true
  def handle_event("invite", %{"email" => email, "role" => role}, socket) do
    org = socket.assigns.current_organization

    if org.personal do
      {:noreply,
       assign(socket, :invite_error, "Cannot invite members to a personal organization.")}
    else
      case Accounts.add_member(org.id, String.trim(email), role) do
        {:ok, _membership} ->
          members = Accounts.list_members(org.id)

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
    case Accounts.update_member_role(membership_id, new_role) do
      {:ok, _} ->
        members = Accounts.list_members(socket.assigns.current_organization.id)
        {:noreply, assign(socket, :members, members)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update role.")}
    end
  end

  def handle_event("remove", %{"id" => membership_id}, socket) do
    case Accounts.remove_member(membership_id) do
      {:ok, _} ->
        members = Accounts.list_members(socket.assigns.current_organization.id)

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

    case Accounts.transfer_ownership(org.id, new_owner_id) do
      :ok ->
        members = Accounts.list_members(org.id)
        membership = Accounts.get_membership(socket.assigns.current_user.id, org.id)

        {:noreply,
         socket
         |> assign(:members, members)
         |> assign(:current_membership, membership)
         |> assign(:is_owner, false)
         |> assign(:can_manage, Authorization.can?(membership, :manage_members))
         |> put_flash(:info, "Ownership transferred.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to transfer ownership.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Members" subtitle={"Manage members of #{@current_organization.name}"}>
        <:actions>
          <.link navigate={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-secondary">
            Back
          </.link>
        </:actions>
      </.page_header>

      <div :if={@can_manage && !@current_organization.personal} class="form-card">
        <h3 class="form-section-title">Add Member</h3>
        <form phx-submit="invite" class="invite-form">
          <div class="invite-row">
            <input
              type="email"
              name="email"
              value={@invite_email}
              placeholder="user@example.com"
              class="form-input"
              required
            />
            <select name="role" class="form-select">
              <option value="member">Member</option>
              <option value="admin">Admin</option>
              <option value="viewer">Viewer</option>
            </select>
            <button type="submit" class="btn-primary">Add</button>
          </div>
          <p :if={@invite_error} class="form-error"><%= @invite_error %></p>
        </form>
      </div>

      <div :if={@current_organization.personal} class="form-card">
        <p class="muted-text">Personal organizations are single-user only. Create a team organization to collaborate.</p>
      </div>

      <table class="rho-table">
        <thead>
          <tr>
            <th>Email</th>
            <th>Name</th>
            <th>Role</th>
            <th :if={@can_manage}>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={member <- @members}>
            <td><%= member.email %></td>
            <td><%= member.display_name || "—" %></td>
            <td>
              <%= if @can_manage && member.role != "owner" do %>
                <form phx-change="change_role" class="inline-form">
                  <input type="hidden" name="membership_id" value={member.id} />
                  <select name="role" class="form-select-sm">
                    <option value="admin" selected={member.role == "admin"}>Admin</option>
                    <option value="member" selected={member.role == "member"}>Member</option>
                    <option value="viewer" selected={member.role == "viewer"}>Viewer</option>
                  </select>
                </form>
              <% else %>
                <%= member.role %>
              <% end %>
            </td>
            <td :if={@can_manage}>
              <%= if member.role != "owner" do %>
                <button
                  phx-click="remove"
                  phx-value-id={member.id}
                  data-confirm={"Remove #{member.email} from this organization?"}
                  class="btn-danger-sm"
                >
                  Remove
                </button>
                <%= if @is_owner do %>
                  <button
                    phx-click="transfer_ownership"
                    phx-value-user-id={member.user_id}
                    data-confirm={"Transfer ownership to #{member.email}? You will be demoted to admin."}
                    class="btn-secondary-sm"
                  >
                    Make Owner
                  </button>
                <% end %>
              <% else %>
                <span class="badge-muted">Owner</span>
              <% end %>
            </td>
          </tr>
        </tbody>
      </table>
    </.page_shell>
    """
  end
end
