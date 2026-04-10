defmodule RhoWeb.RoleProfileShowLive do
  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  import RhoWeb.CoreComponents

  alias RhoFrameworks.Roles

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {profile, role_skills} =
      if connected?(socket) do
        org = socket.assigns.current_organization

        rp =
          Roles.get_role_profile!(org.id, id) |> RhoFrameworks.Repo.preload(role_skills: :skill)

        grouped = group_skills(rp.role_skills)
        {rp, grouped}
      else
        {nil, %{}}
      end

    {:ok, assign(socket, profile: profile, role_skills: role_skills, active_page: :roles)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell>
      <div :if={@profile} class="breadcrumb">
        <.link navigate={~p"/orgs/#{@current_organization.slug}/roles"}>Roles</.link>
        <span class="breadcrumb-sep">/</span>
        <span><%= @profile.name %></span>
      </div>

      <.page_header :if={@profile} title={@profile.name} subtitle={role_subtitle(@profile)}>
        <:actions>
          <.link navigate={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-secondary">
            Edit in Chat
          </.link>
        </:actions>
      </.page_header>

      <%= if @profile do %>
        <div :if={has_rich_fields?(@profile)} class="fw-section">
          <h2 class="fw-section-title">Role Description</h2>
          <div class="role-description">
            <div :if={@profile.purpose} class="role-field role-field--full">
              <h3 class="role-field-label">Purpose</h3>
              <p><%= @profile.purpose %></p>
            </div>
            <div :if={@profile.accountabilities} class="role-field">
              <h3 class="role-field-label">Accountabilities</h3>
              <p><%= @profile.accountabilities %></p>
            </div>
            <div :if={@profile.success_metrics} class="role-field">
              <h3 class="role-field-label">Success Metrics</h3>
              <p><%= @profile.success_metrics %></p>
            </div>
            <div :if={@profile.qualifications} class="role-field">
              <h3 class="role-field-label">Qualifications</h3>
              <p><%= @profile.qualifications %></p>
            </div>
            <div :if={@profile.reporting_context} class="role-field">
              <h3 class="role-field-label">Reporting Context</h3>
              <p><%= @profile.reporting_context %></p>
            </div>
          </div>
        </div>

        <div class="fw-section">
          <h2 class="fw-section-title">Skill Requirements</h2>

          <details :for={{category, clusters} <- @role_skills} class="fw-collapse">
            <summary class="fw-collapse-summary">
              <span class="fw-collapse-arrow"></span>
              <span class="fw-cluster-title"><%= category %></span>
              <span class="badge-muted"><%= Enum.sum(Enum.map(clusters, fn {_, s} -> length(s) end)) %> skills</span>
            </summary>

            <div class="fw-collapse-body">
              <details :for={{cluster, skills} <- clusters} class="fw-collapse fw-collapse--nested">
                <summary class="fw-collapse-summary">
                  <span class="fw-collapse-arrow"></span>
                  <span class="fw-category-title"><%= cluster %></span>
                  <span class="badge-muted"><%= length(skills) %></span>
                </summary>

                <div class="fw-collapse-body">
                  <table class="rho-table">
                    <thead>
                      <tr>
                        <th>Skill</th>
                        <th>Level</th>
                        <th>Required</th>
                        <th>Weight</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={rs <- skills}>
                        <td><%= rs.skill.name %></td>
                        <td>
                          <span class={"badge-level #{if rs.required, do: "badge-level--required", else: "badge-level--optional"}"}>
                            <%= rs.min_expected_level %>
                          </span>
                        </td>
                        <td>
                          <span class={"required-dot #{unless rs.required, do: "required-dot--no"}"} title={if rs.required, do: "Required", else: "Nice-to-have"} />
                        </td>
                        <td><%= rs.weight %></td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </details>
            </div>
          </details>
        </div>

        <div :if={@profile.work_activities != []} class="fw-section">
          <h2 class="fw-section-title">Work Activities</h2>
          <table class="rho-table">
            <thead>
              <tr>
                <th>Activity</th>
                <th>Frequency</th>
                <th>Time Allocation</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={activity <- @profile.work_activities}>
                <td><%= activity["description"] || activity[:description] %></td>
                <td><%= activity["frequency"] || activity[:frequency] %></td>
                <td><%= activity["time_allocation"] || activity[:time_allocation] %></td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </.page_shell>
    """
  end

  defp role_subtitle(profile) do
    parts =
      [profile.role_family, profile.seniority_label, profile.description]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))

    if parts == [], do: nil, else: Enum.join(parts, " - ")
  end

  defp has_rich_fields?(profile) do
    Enum.any?(
      [
        profile.purpose,
        profile.accountabilities,
        profile.success_metrics,
        profile.qualifications,
        profile.reporting_context
      ],
      &(&1 != nil && &1 != "")
    )
  end

  defp group_skills(role_skills) do
    role_skills
    |> Enum.sort_by(fn rs -> {rs.skill.category, rs.skill.cluster, rs.skill.name} end)
    |> Enum.group_by(fn rs -> rs.skill.category || "Other" end)
    |> Enum.sort_by(fn {cat, _} -> cat end)
    |> Enum.map(fn {category, skills} ->
      clusters =
        skills
        |> Enum.group_by(fn rs -> rs.skill.cluster || "General" end)
        |> Enum.sort_by(fn {cluster, _} -> cluster end)

      {category, clusters}
    end)
  end
end
