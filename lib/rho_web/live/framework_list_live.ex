defmodule RhoWeb.FrameworkListLive do
  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  import RhoWeb.CoreComponents

  alias Rho.Frameworks

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    frameworks = Frameworks.list_frameworks(user.id)

    {:ok, assign(socket, frameworks: frameworks, active_page: :frameworks)}
  end

  @impl true
  def handle_event("delete", %{"name" => name}, socket) do
    user = socket.assigns.current_user
    Frameworks.delete_framework(user.id, name)
    frameworks = Frameworks.list_frameworks(user.id)
    {:noreply, assign(socket, frameworks: frameworks)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Skill Frameworks" subtitle="Manage your saved skill frameworks">
        <:actions>
          <.link navigate={~p"/spreadsheet"} class="btn-primary">+ New Framework</.link>
        </:actions>
      </.page_header>

      <.empty_state :if={@frameworks == []}>
        No frameworks yet. Create one in the spreadsheet editor.
      </.empty_state>

      <div :if={@frameworks != []} class="framework-grid">
        <.card :for={fw <- @frameworks}>
          <div class="framework-card-top">
            <.link navigate={~p"/frameworks/#{fw.id}"} class="framework-card-name">
              <%= fw.name %>
            </.link>
            <span class="badge-muted"><%= fw.skill_count %> skills</span>
          </div>
          <p :if={fw.description} class="framework-card-desc"><%= fw.description %></p>
          <div class="framework-card-footer">
            <span class="framework-card-date">
              Updated <%= Calendar.strftime(fw.updated_at, "%b %d, %Y") %>
            </span>
            <button
              phx-click="delete"
              phx-value-name={fw.name}
              data-confirm={"Delete framework '#{fw.name}'?"}
              class="btn-danger-sm"
            >
              Delete
            </button>
          </div>
        </.card>
      </div>
    </.page_shell>
    """
  end
end
