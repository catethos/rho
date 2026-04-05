defmodule RhoWeb.FrameworkShowLive do
  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  import RhoWeb.CoreComponents

  alias Rho.Frameworks

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user
    framework = Frameworks.get_framework_with_skills!(user.id, id)
    grouped = group_skills(framework.skills)

    {:ok, assign(socket, framework: framework, grouped: grouped, active_page: :frameworks)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell>
      <div class="breadcrumb">
        <.link navigate={~p"/frameworks"}>Frameworks</.link>
        <span class="breadcrumb-sep">/</span>
        <span><%= @framework.name %></span>
      </div>

      <.page_header title={@framework.name} subtitle={@framework.description}>
        <:actions>
          <.link navigate={~p"/spreadsheet"} class="btn-secondary">Edit in Spreadsheet</.link>
        </:actions>
      </.page_header>

      <div :for={{category, clusters} <- @grouped} class="fw-section">
        <h2 class="fw-section-title"><%= category %></h2>
        <div :for={{cluster, skills} <- clusters} class="fw-cluster">
          <h3 class="fw-cluster-title"><%= cluster %></h3>
          <table class="rho-table">
            <thead>
              <tr>
                <th>Skill</th>
                <th>Description</th>
                <th>Level</th>
                <th>Level Name</th>
                <th>Level Description</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={skill <- skills}>
                <td><%= skill.skill_name %></td>
                <td><%= skill.skill_description %></td>
                <td><%= skill.level %></td>
                <td><%= skill.level_name %></td>
                <td><%= skill.level_description %></td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.page_shell>
    """
  end

  defp group_skills(skills) do
    skills
    |> Enum.group_by(& &1.category)
    |> Enum.map(fn {cat, cat_skills} ->
      clusters =
        cat_skills
        |> Enum.group_by(& &1.cluster)
        |> Enum.map(fn {cluster, cluster_skills} ->
          {cluster, Enum.sort_by(cluster_skills, & &1.sort_order)}
        end)

      {cat, clusters}
    end)
  end
end
