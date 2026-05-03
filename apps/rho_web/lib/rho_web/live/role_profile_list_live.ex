defmodule RhoWeb.RoleProfileListLive do
  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  import RhoWeb.CoreComponents

  alias RhoFrameworks.Roles

  @impl true
  def mount(_params, _session, socket) do
    profiles =
      if connected?(socket) do
        org = socket.assigns.current_organization
        Roles.list_role_profiles(org.id, include_public: false)
      else
        []
      end

    grouped = group_by_family(profiles)

    {:ok, assign(socket, profiles: profiles, grouped: grouped, active_page: :roles)}
  end

  @impl true
  def handle_event("delete", %{"name" => name}, socket) do
    org = socket.assigns.current_organization
    Roles.delete_role_profile(org.id, name)
    profiles = Roles.list_role_profiles(org.id, include_public: false)
    {:noreply, assign(socket, profiles: profiles, grouped: group_by_family(profiles))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Role Profiles" subtitle="Manage role profiles and skill requirements">
        <:actions>
          <.link navigate={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-primary">
            + New Role Profile
          </.link>
        </:actions>
      </.page_header>

      <.empty_state :if={@profiles == []}>
        No role profiles yet. Create one in the chat editor.
      </.empty_state>

      <div :for={{family, family_profiles} <- @grouped} class="fw-section">
        <h2 :if={family} class="fw-section-title"><%= family %></h2>
        <div class="framework-grid">
          <.card :for={rp <- family_profiles}>
            <div class="framework-card-top">
              <.link
                navigate={~p"/orgs/#{@current_organization.slug}/roles/#{rp.id}"}
                class="framework-card-name"
              >
                <%= rp.name %>
              </.link>
              <div class="framework-card-badges">
                <span :if={rp.seniority_label} class="badge-muted"><%= rp.seniority_label %></span>
                <span class="badge-muted"><%= rp.skill_count %> skills</span>
              </div>
            </div>
            <p :if={rp.purpose} class="framework-card-desc"><%= rp.purpose %></p>
            <div class="framework-card-footer">
              <span class="framework-card-date">
                Updated <%= Calendar.strftime(rp.updated_at, "%b %d, %Y") %>
              </span>
              <button
                phx-click="delete"
                phx-value-name={rp.name}
                data-confirm={"Delete role profile '#{rp.name}'?"}
                class="btn-danger-sm"
              >
                Delete
              </button>
            </div>
          </.card>
        </div>
      </div>
    </.page_shell>
    """
  end

  defp group_by_family(profiles) do
    profiles
    |> Enum.group_by(& &1.role_family)
    |> Enum.sort_by(fn {family, _} -> family || "" end)
  end
end
