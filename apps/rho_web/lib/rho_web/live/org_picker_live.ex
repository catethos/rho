defmodule RhoWeb.OrgPickerLive do
  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  import RhoWeb.CoreComponents

  alias RhoFrameworks.Accounts

  @impl true
  def mount(_params, _session, socket) do
    orgs_with_counts =
      if connected?(socket) do
        user = socket.assigns.current_user
        Accounts.list_user_organizations_with_counts(user.id)
      else
        []
      end

    changeset = Accounts.change_organization(%Accounts.Organization{})

    {:ok,
     socket
     |> assign(:orgs, orgs_with_counts)
     |> assign(:show_create, false)
     |> assign(:changeset, to_form(changeset))
     |> assign(:active_page, nil)}
  end

  @impl true
  def handle_event("toggle_create", _params, socket) do
    {:noreply, assign(socket, :show_create, !socket.assigns.show_create)}
  end

  def handle_event("create_org", %{"organization" => params}, socket) do
    user = socket.assigns.current_user
    slug = slugify(params["name"])
    attrs = Map.put(params, "slug", slug)

    case Accounts.create_organization(attrs, user) do
      {:ok, org} ->
        {:noreply, push_navigate(socket, to: ~p"/orgs/#{org.slug}/chat")}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Organizations" subtitle="Select an organization to continue">
        <:actions>
          <button phx-click="toggle_create" class="btn-primary">+ New Organization</button>
        </:actions>
      </.page_header>

      <div :if={@show_create} class="org-create-form">
        <.form for={@changeset} phx-submit="create_org" class="form-card">
          <div class="form-group">
            <label for="org_name" class="form-label">Organization Name</label>
            <input
              type="text"
              name="organization[name]"
              id="org_name"
              value={@changeset[:name].value}
              class="form-input"
              placeholder="My Team"
              required
              maxlength="100"
            />
            <p :if={@changeset[:name].errors != []} class="form-error">
              <%= elem(hd(@changeset[:name].errors), 0) %>
            </p>
          </div>
          <div class="form-actions">
            <button type="submit" class="btn-primary">Create</button>
            <button type="button" phx-click="toggle_create" class="btn-secondary">Cancel</button>
          </div>
        </.form>
      </div>

      <.empty_state :if={@orgs == []}>
        No organizations yet. Create one to get started.
      </.empty_state>

      <div :if={@orgs != []} class="framework-grid">
        <.card :for={entry <- @orgs}>
          <.link navigate={~p"/orgs/#{entry.organization.slug}/chat"} class="org-card-link">
            <div class="framework-card-top">
              <span class="framework-card-name">
                <%= org_label(entry.organization) %>
              </span>
              <span class="badge-muted"><%= entry.role %></span>
            </div>
            <div class="framework-card-footer">
              <span :if={!entry.organization.personal} class="framework-card-date">
                <%= entry.member_count %> member<%= if entry.member_count != 1, do: "s" %>
              </span>
              <span :if={entry.organization.personal} class="framework-card-date">
                Personal workspace
              </span>
            </div>
          </.link>
        </.card>
      </div>
    </.page_shell>
    """
  end

  defp org_label(%{personal: true}), do: "Personal"
  defp org_label(%{name: name}), do: name

  defp slugify(nil), do: ""

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
  end
end
