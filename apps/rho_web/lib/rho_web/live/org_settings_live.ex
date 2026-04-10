defmodule RhoWeb.OrgSettingsLive do
  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  import RhoWeb.CoreComponents

  alias RhoFrameworks.Accounts
  alias RhoFrameworks.Accounts.Authorization

  @impl true
  def mount(_params, _session, socket) do
    org = socket.assigns.current_organization
    user = socket.assigns.current_user
    membership = socket.assigns.current_membership
    changeset = Accounts.change_organization(org)
    user_changeset = Accounts.change_user_profile(user)

    {:ok,
     socket
     |> assign(:changeset, to_form(changeset))
     |> assign(:user_changeset, to_form(user_changeset, as: "user"))
     |> assign(:is_owner, Authorization.can?(membership, :manage_org))
     |> assign(:active_page, :settings)}
  end

  @impl true
  def handle_event("save", %{"organization" => params}, socket) do
    org = socket.assigns.current_organization

    case Accounts.update_organization(org, params) do
      {:ok, updated_org} ->
        {:noreply,
         socket
         |> assign(:current_organization, updated_org)
         |> assign(:changeset, to_form(Accounts.change_organization(updated_org)))
         |> put_flash(:info, "Organization updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, to_form(changeset))}
    end
  end

  def handle_event("save_profile", %{"user" => params}, socket) do
    user = socket.assigns.current_user

    case Accounts.update_user_profile(user, params) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:user_changeset, to_form(Accounts.change_user_profile(updated_user), as: "user"))
         |> put_flash(:info, "Profile updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :user_changeset, to_form(changeset, as: "user"))}
    end
  end

  def handle_event("delete_org", _params, socket) do
    org = socket.assigns.current_organization
    membership = socket.assigns.current_membership

    cond do
      !Authorization.can?(membership, :manage_org) ->
        {:noreply, put_flash(socket, :error, "Only the owner can delete this organization.")}

      org.personal ->
        {:noreply, put_flash(socket, :error, "Personal organizations cannot be deleted.")}

      true ->
        case Accounts.delete_organization(org) do
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

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Organization Settings" subtitle={"Manage #{@current_organization.name}"}>
        <:actions>
          <.link navigate={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-secondary">
            Back
          </.link>
        </:actions>
      </.page_header>

      <div class="form-card">
        <.form for={@changeset} phx-submit="save">
          <div class="form-group">
            <label for="org_name" class="form-label">Name</label>
            <input
              type="text"
              name="organization[name]"
              id="org_name"
              value={@changeset[:name].value}
              class="form-input"
              required
              maxlength="100"
            />
            <p :if={@changeset[:name].errors != []} class="form-error">
              <%= elem(hd(@changeset[:name].errors), 0) %>
            </p>
          </div>

          <div class="form-group">
            <label class="form-label">Slug (immutable)</label>
            <input
              type="text"
              value={@current_organization.slug}
              class="form-input"
              disabled
            />
          </div>

          <div class="form-group">
            <label class="form-label">Organization ID</label>
            <code class="form-code"><%= @current_organization.id %></code>
          </div>

          <div class="form-group">
            <label for="org_context" class="form-label">Organization Context</label>
            <p class="form-hint">Extra context the AI agent should know about this organization.</p>
            <textarea
              name="organization[context]"
              id="org_context"
              class="form-input"
              rows="4"
              placeholder="e.g. We are a machine learning research team focused on NLP..."
            ><%= @changeset[:context].value %></textarea>
          </div>

          <div class="form-actions">
            <button type="submit" class="btn-primary">Save Changes</button>
          </div>
        </.form>
      </div>

      <div class="form-card">
        <h3 class="form-card-title">Your Profile</h3>
        <.form for={@user_changeset} phx-submit="save_profile">
          <div class="form-group">
            <label for="user_display_name" class="form-label">Display Name</label>
            <input
              type="text"
              name="user[display_name]"
              id="user_display_name"
              value={@user_changeset[:display_name].value}
              class="form-input"
            />
          </div>

          <div class="form-group">
            <label for="user_context" class="form-label">User Context</label>
            <p class="form-hint">Extra context the AI agent should know about you.</p>
            <textarea
              name="user[context]"
              id="user_context"
              class="form-input"
              rows="4"
              placeholder="e.g. I'm a senior engineer, prefer concise answers..."
            ><%= @user_changeset[:context].value %></textarea>
          </div>

          <div class="form-actions">
            <button type="submit" class="btn-primary">Save Profile</button>
          </div>
        </.form>
      </div>

      <div :if={@is_owner && !@current_organization.personal} class="form-card danger-zone">
        <h3 class="danger-title">Danger Zone</h3>
        <p class="danger-desc">
          Deleting this organization will permanently remove all its data, including frameworks and memberships.
        </p>
        <button
          phx-click="delete_org"
          data-confirm={"Are you sure you want to delete '#{@current_organization.name}'? This cannot be undone."}
          class="btn-danger"
        >
          Delete Organization
        </button>
      </div>
    </.page_shell>
    """
  end
end
