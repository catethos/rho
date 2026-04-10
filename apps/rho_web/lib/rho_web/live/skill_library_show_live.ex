defmodule RhoWeb.SkillLibraryShowLive do
  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  import RhoWeb.CoreComponents

  alias RhoFrameworks.Library

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {library, skills} =
      if connected?(socket) do
        org = socket.assigns.current_organization
        lib = Library.get_library!(org.id, id)
        skills = Library.browse_library(id)
        {lib, skills}
      else
        {nil, []}
      end

    grouped = group_skills(skills)

    {:ok,
     assign(socket,
       library: library,
       skills: skills,
       grouped: grouped,
       status_filter: nil,
       active_page: :libraries,
       show_fork_modal: false,
       fork_name: "",
       show_diff: false,
       diff_result: nil
     )}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    status = if status == "", do: nil, else: status
    opts = if status, do: [status: status], else: []
    skills = Library.browse_library(socket.assigns.library.id, opts)

    {:noreply,
     assign(socket, skills: skills, grouped: group_skills(skills), status_filter: status)}
  end

  def handle_event("open_fork_modal", _params, socket) do
    default_name = "#{socket.assigns.library.name} (Custom)"
    {:noreply, assign(socket, show_fork_modal: true, fork_name: default_name)}
  end

  def handle_event("close_fork_modal", _params, socket) do
    {:noreply, assign(socket, show_fork_modal: false)}
  end

  def handle_event("update_fork_name", %{"fork_name" => name}, socket) do
    {:noreply, assign(socket, fork_name: name)}
  end

  def handle_event("submit_fork", %{"fork_name" => name}, socket) do
    org = socket.assigns.current_organization
    lib = socket.assigns.library

    case Library.fork_library(org.id, lib.id, String.trim(name)) do
      {:ok, %{library: forked}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Forked \"#{lib.name}\" → \"#{forked.name}\"")
         |> push_navigate(to: ~p"/orgs/#{org.slug}/libraries/#{forked.id}")}

      {:error, _step, reason, _changes} ->
        {:noreply, put_flash(socket, :error, "Fork failed: #{inspect(reason)}")}
    end
  end

  def handle_event("show_diff", _params, socket) do
    org = socket.assigns.current_organization
    lib = socket.assigns.library

    case Library.diff_against_source(org.id, lib.id) do
      {:ok, diff} ->
        {:noreply, assign(socket, show_diff: true, diff_result: diff)}

      {:error, _code, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("hide_diff", _params, socket) do
    {:noreply, assign(socket, show_diff: false, diff_result: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell>
      <div :if={@library} class="breadcrumb">
        <.link navigate={~p"/orgs/#{@current_organization.slug}/libraries"}>Libraries</.link>
        <span class="breadcrumb-sep">/</span>
        <span><%= @library.name %></span>
      </div>

      <.page_header :if={@library} title={@library.name} subtitle={@library.description}>
        <:actions>
          <span :if={@library.immutable} class="badge-immutable">Standard (read-only)</span>
          <button :if={@library.immutable} phx-click="open_fork_modal" class="btn-primary">
            Fork Library
          </button>
          <button :if={@library.derived_from_id} phx-click={if @show_diff, do: "hide_diff", else: "show_diff"} class="btn-secondary">
            <%= if @show_diff, do: "Hide Diff", else: "Compare to Source" %>
          </button>
          <.link navigate={~p"/orgs/#{@current_organization.slug}/chat?library_id=#{@library.id}"} class="btn-secondary">
            Open in Chat
          </.link>
        </:actions>
      </.page_header>

      <%= if @show_fork_modal do %>
        <div class="modal-backdrop" phx-click="close_fork_modal">
          <div class="modal-content" phx-click-away="close_fork_modal">
            <h2 class="modal-title">Fork Library</h2>
            <p class="modal-desc">Create a mutable copy of "<%= @library.name %>" that you can customize.</p>
            <form phx-submit="submit_fork">
              <label class="form-label" for="fork_name">Library name</label>
              <input
                type="text"
                name="fork_name"
                id="fork_name"
                value={@fork_name}
                phx-change="update_fork_name"
                class="form-input"
                autofocus
              />
              <div class="modal-actions">
                <button type="button" phx-click="close_fork_modal" class="btn-secondary">Cancel</button>
                <button type="submit" class="btn-primary">Fork</button>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <%= if @show_diff && @diff_result do %>
        <div class="diff-panel">
          <h3 class="diff-title">Changes from source</h3>
          <div class="diff-stats">
            <span class="diff-stat diff-added"><%= length(@diff_result.added) %> added</span>
            <span class="diff-stat diff-removed"><%= length(@diff_result.removed) %> removed</span>
            <span class="diff-stat diff-modified"><%= length(@diff_result.modified) %> modified</span>
            <span class="diff-stat diff-unchanged"><%= @diff_result.unchanged_count %> unchanged</span>
          </div>
          <div :if={@diff_result.added != []} class="diff-section">
            <h4>Added</h4>
            <ul><li :for={name <- @diff_result.added}><%= name %></li></ul>
          </div>
          <div :if={@diff_result.removed != []} class="diff-section">
            <h4>Removed</h4>
            <ul><li :for={name <- @diff_result.removed}><%= name %></li></ul>
          </div>
          <div :if={@diff_result.modified != []} class="diff-section">
            <h4>Modified</h4>
            <ul><li :for={name <- @diff_result.modified}><%= name %></li></ul>
          </div>
        </div>
      <% end %>

      <div :if={@library} class="filter-bar">
        <form phx-change="filter_status">
          <select name="status" class="filter-select">
            <option value="" selected={@status_filter == nil}>All statuses</option>
            <option value="draft" selected={@status_filter == "draft"}>Draft</option>
            <option value="published" selected={@status_filter == "published"}>Published</option>
            <option value="archived" selected={@status_filter == "archived"}>Archived</option>
          </select>
        </form>
        <span class="filter-count"><%= length(@skills) %> skills</span>
      </div>

      <div :for={{category, clusters} <- @grouped} class="fw-collapse"
        id={"cat-#{category}"} phx-update="ignore">
        <details>
          <summary class="fw-collapse-summary">
            <span class="fw-collapse-arrow"></span>
            <span class="fw-cluster-title"><%= category %></span>
            <span class="badge-muted"><%= Enum.sum(Enum.map(clusters, fn {_, s} -> length(s) end)) %> skills</span>
          </summary>

          <div class="fw-collapse-body">
            <details :for={{cluster, cluster_skills} <- clusters} class="fw-collapse fw-collapse--nested">
              <summary class="fw-collapse-summary">
                <span class="fw-collapse-arrow"></span>
                <span class="fw-category-title"><%= cluster %></span>
                <span class="badge-muted"><%= length(cluster_skills) %></span>
              </summary>

              <div class="fw-collapse-body">
                <table class="rho-table">
                  <thead>
                    <tr>
                      <th>Skill</th>
                      <th>Description</th>
                      <th>Status</th>
                      <th>Levels</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for skill <- cluster_skills do %>
                      <tr class="skill-row" onclick={"this.classList.toggle('skill-expanded');document.getElementById('prof-#{skill.id}').classList.toggle('proficiency-hidden')"} style="cursor: pointer;">
                        <td><span class="skill-expand-arrow"></span><%= skill.name %></td>
                        <td><%= skill.description %></td>
                        <td>
                          <span class={"badge-#{skill.status}"}><%= skill.status %></span>
                        </td>
                        <td><%= length(skill.proficiency_levels || []) %></td>
                      </tr>
                      <tr :if={(skill.proficiency_levels || []) != []}
                        id={"prof-#{skill.id}"} class="proficiency-hidden">
                        <td colspan="4" style="padding: 0;">
                          <div class="proficiency-panel">
                            <div class="proficiency-list">
                              <div :for={level <- Enum.sort_by(skill.proficiency_levels, & &1["level"])} class="proficiency-item">
                                <span class="proficiency-level">L<%= level["level"] %></span>
                                <span class="proficiency-name"><%= level["level_name"] %></span>
                                <span class="proficiency-desc"><%= level["level_description"] %></span>
                              </div>
                            </div>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </details>
          </div>
        </details>
      </div>
    </.page_shell>
    """
  end

  defp group_skills(skills) do
    skills
    |> Enum.sort_by(fn s -> {s.category, s.cluster, s.name} end)
    |> Enum.group_by(fn s -> s.category || "Other" end)
    |> Enum.sort_by(fn {cat, _} -> cat end)
    |> Enum.map(fn {category, cat_skills} ->
      clusters =
        cat_skills
        |> Enum.group_by(fn s -> s.cluster || "General" end)
        |> Enum.sort_by(fn {cluster, _} -> cluster end)

      {category, clusters}
    end)
  end
end
