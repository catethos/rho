defmodule RhoWeb.AppLive.PageComponents do
  @moduledoc """
  Page render components for `RhoWeb.AppLive`.

  AppLive owns routing, session state, and event delegation. This module owns
  the page templates that render already-loaded library, role, settings, and
  member assigns.
  """
  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  import RhoWeb.CoreComponents

  alias RhoWeb.AppLive.PageSearchEvents

  def libraries(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Skill Libraries" subtitle="Browse and manage skill catalogs">
        <:actions>
          <.link patch={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-primary">
            + New Library
          </.link>
        </:actions>
      </.page_header>

      <section class="smart-entry" aria-label="Describe what you want to build">
        <h3 class="smart-entry-title">Or describe it in plain English</h3>
        <p class="smart-entry-hint">
          e.g. <em>"create a framework for backend engineers"</em> — we'll start the workflow in chat with the right context.
        </p>
        <form phx-submit="smart_entry_submit" class="smart-entry-form">
          <textarea
            name="message"
            class="smart-entry-textarea"
            rows="2"
            placeholder="Describe the framework you want to build…"
            disabled={@smart_entry_pending?}
            required
          ></textarea>
          <button type="submit" class="btn-secondary" disabled={@smart_entry_pending?}>
            <%= if @smart_entry_pending?, do: "Matching…", else: "Suggest →" %>
          </button>
        </form>
      </section>

      <form phx-change="search_libraries" phx-submit="search_libraries" class="search-bar">
        <input
          type="search"
          name="q"
          value={@library_search_query}
          placeholder="Filter libraries by name…"
          phx-debounce="150"
          class="search-input"
          autocomplete="off"
        />
      </form>

      <% filtered_groups = PageSearchEvents.filter_library_groups(@library_groups, @library_search_query) %>

      <.empty_state :if={@library_groups == []}>
        No libraries yet. Create one in the chat editor or load a standard template.
      </.empty_state>

      <.empty_state :if={@library_groups != [] && filtered_groups == []}>
        No libraries match "<%= @library_search_query %>".
      </.empty_state>

      <div :if={filtered_groups != []} class="lib-list">
        <div class="lib-list-header">
          <span class="lib-col-name">Name</span>
          <span class="lib-col-version">Version</span>
          <span class="lib-col-skills">Skills</span>
          <span class="lib-col-updated">Updated</span>
          <span class="lib-col-actions"></span>
        </div>

        <%= for group <- filtered_groups do %>
          <details class="lib-group" open={group.version_count == 1}>
            <summary class="lib-row lib-row-primary">
              <span class="lib-col-name">
                <.link
                  patch={~p"/orgs/#{@current_organization.slug}/libraries/#{group.primary.id}"}
                  class="lib-name-link"
                >
                  <%= group.name %>
                </.link>
                <span :if={group.primary.visibility == "public"} class="badge-public">Public</span>
                <span :if={group.version_count > 1} class="badge-muted">
                  <%= group.version_count %> versions
                </span>
              </span>
              <span class="lib-col-version">
                <span :if={group.primary.version} class="badge-version">
                  v<%= group.primary.version %>
                </span>
                <span :if={group.primary.is_default} class="badge-default">Default</span>
                <span :if={!group.primary.version && !group.primary.immutable} class="badge-draft">
                  Draft
                </span>
                <span :if={group.primary.immutable && !group.primary.version} class="badge-immutable">
                  Standard
                </span>
              </span>
              <span class="lib-col-skills"><%= group.primary.skill_count %></span>
              <span class="lib-col-updated">
                <%= if group.primary.published_at do %>
                  <%= Calendar.strftime(group.primary.published_at, "%b %d, %Y %H:%M") %>
                <% else %>
                  <%= Calendar.strftime(group.primary.updated_at, "%b %d, %Y %H:%M") %>
                <% end %>
              </span>
              <span class="lib-col-actions">
                <button
                  :if={group.primary.version && !group.primary.is_default && group.primary.visibility != "public"}
                  phx-click="set_default_version"
                  phx-value-id={group.primary.id}
                  class="btn-secondary-sm"
                >
                  Set as Default
                </button>
                <.link
                  :if={group.primary.visibility != "public" && !group.primary.immutable}
                  navigate={~p"/orgs/#{@current_organization.slug}/flows/edit-framework?library_id=#{group.primary.id}"}
                  class="btn-secondary-sm"
                >
                  Edit
                </.link>
                <button
                  phx-click="fork_and_edit"
                  phx-value-id={group.primary.id}
                  class="btn-secondary-sm"
                  disabled={@fork_pending?}
                >
                  <%= if @fork_pending?, do: "Forking…", else: "Fork" %>
                </button>
                <button
                  :if={group.primary.visibility != "public"}
                  phx-click="delete_library"
                  phx-value-id={group.primary.id}
                  data-confirm={"Delete '#{group.name}' and all its skills?"}
                  class="btn-danger-sm"
                >
                  Delete
                </button>
              </span>
            </summary>

            <%= for lib <- Enum.drop(group.versions, 1) do %>
              <div class="lib-row lib-row-version">
                <span class="lib-col-name lib-version-indent">
                  <.link
                    patch={~p"/orgs/#{@current_organization.slug}/libraries/#{lib.id}"}
                    class="lib-name-link"
                  >
                    <%= lib.name %>
                  </.link>
                </span>
                <span class="lib-col-version">
                  <span :if={lib.version} class="badge-version">v<%= lib.version %></span>
                  <span :if={lib.is_default} class="badge-default">Default</span>
                  <span :if={!lib.version && !lib.immutable} class="badge-draft">Draft</span>
                  <span :if={lib.immutable && !lib.version} class="badge-immutable">Standard</span>
                </span>
                <span class="lib-col-skills"><%= lib.skill_count %></span>
                <span class="lib-col-updated">
                  <%= if lib.published_at do %>
                    <%= Calendar.strftime(lib.published_at, "%b %d, %Y %H:%M") %>
                  <% else %>
                    <%= Calendar.strftime(lib.updated_at, "%b %d, %Y %H:%M") %>
                  <% end %>
                </span>
                <span class="lib-col-actions">
                  <button
                    :if={lib.version && !lib.is_default && lib.visibility != "public"}
                    phx-click="set_default_version"
                    phx-value-id={lib.id}
                    class="btn-secondary-sm"
                  >
                    Set as Default
                  </button>
                  <.link
                    :if={lib.visibility != "public" && !lib.immutable}
                    navigate={~p"/orgs/#{@current_organization.slug}/flows/edit-framework?library_id=#{lib.id}"}
                    class="btn-secondary-sm"
                  >
                    Edit
                  </.link>
                  <button
                    phx-click="fork_and_edit"
                    phx-value-id={lib.id}
                    class="btn-secondary-sm"
                    disabled={@fork_pending?}
                  >
                    <%= if @fork_pending?, do: "Forking…", else: "Fork" %>
                  </button>
                  <button
                    :if={lib.visibility != "public"}
                    phx-click="delete_library"
                    phx-value-id={lib.id}
                    data-confirm={"Delete this version of '#{lib.name}'?"}
                    class="btn-danger-sm"
                  >
                    Delete
                  </button>
                </span>
              </div>
            <% end %>
          </details>
        <% end %>
      </div>
    </.page_shell>
    """
  end

  def library_show(assigns) do
    search_active? = String.trim(assigns[:skill_search_query] || "") != ""

    assigns =
      assigns
      |> assign(:skill_search_active?, search_active?)
      |> assign(
        :search_grouped,
        if search_active? do
          PageSearchEvents.group_skills(assigns[:skill_search_results] || [])
        else
          []
        end
      )
      |> then(fn a ->
        assign(
          a,
          :filtered_skill_count,
          if search_active? do
            length(a[:skill_search_results] || [])
          else
            0
          end
        )
      end)

    ~H"""
    <.page_shell>
      <div :if={@library} class="breadcrumb">
        <.link patch={~p"/orgs/#{@current_organization.slug}/libraries"}>Libraries</.link>
        <span class="breadcrumb-sep">/</span>
        <span><%= @library.name %></span>
      </div>

      <.page_header :if={@library} title={@library.name} subtitle={@library.description}>
        <:actions>
          <span :if={@library.version} class="badge-version">v<%= @library.version %></span>
          <span :if={@library.is_default} class="badge-default">Default</span>
          <span :if={@library.immutable} class="badge-immutable">Standard (read-only)</span>
          <button
            :if={@library.version && !@library.is_default}
            phx-click="set_default_version_from_show"
            phx-value-id={@library.id}
            class="btn-secondary"
          >
            Set as Default
          </button>
          <button
            :if={@library.immutable}
            phx-click="open_fork_modal"
            class="btn-primary"
            disabled={@fork_pending?}
          >
            <%= if @fork_pending?, do: "Forking…", else: "Fork Library" %>
          </button>
          <button :if={@library.derived_from_id} phx-click={if @show_diff, do: "hide_diff", else: "show_diff"} class="btn-secondary">
            <%= if @show_diff, do: "Hide Diff", else: "Compare to Source" %>
          </button>
          <.link
            patch={~p"/orgs/#{@current_organization.slug}/chat?library_id=#{@library.id}"}
            class="btn-secondary"
          >
            Open in Chat
          </.link>
        </:actions>
      </.page_header>

      <%= if @show_fork_modal do %>
        <div class="modal-backdrop" phx-click="close_fork_modal">
          <div class="modal-content" onclick="event.stopPropagation()">
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

      <details :if={@library && @research_notes != []} class="research-archive">
        <summary class="research-archive-summary">
          <span class="research-archive-arrow"></span>
          <span class="research-archive-title">Research notes</span>
          <span class="badge-muted"><%= length(@research_notes) %></span>
        </summary>
        <ul class="research-archive-list" role="list">
          <li :for={note <- @research_notes} class="research-archive-item">
            <p class="research-fact"><%= note.fact %></p>
            <div class="research-meta">
              <span :if={note.tag} class="research-tag"><%= note.tag %></span>
              <span class="research-source"><%= note.source %></span>
              <span class="research-archive-by">
                <%= if note.inserted_by == "user", do: "added by you", else: "found by agent" %>
              </span>
            </div>
          </li>
        </ul>
      </details>

      <div :if={@library} class="filter-bar">
        <form phx-change="filter_status">
          <select name="status" class="filter-select">
            <option value="" selected={@status_filter == nil}>All statuses</option>
            <option value="draft" selected={@status_filter == "draft"}>Draft</option>
            <option value="published" selected={@status_filter == "published"}>Published</option>
            <option value="archived" selected={@status_filter == "archived"}>Archived</option>
          </select>
        </form>
        <form phx-change="search_skills" phx-submit="search_skills" class="search-bar search-bar--inline">
          <input
            type="search"
            name="q"
            value={@skill_search_query}
            placeholder="Filter skills…"
            phx-debounce="150"
            class="search-input"
            autocomplete="off"
          />
        </form>
        <span class="filter-count">
          <%= if @skill_search_active? do %>
            <%= @filtered_skill_count %> / <%= @total_skill_count %> skills
          <% else %>
            <%= @total_skill_count %> skills
          <% end %>
        </span>
      </div>

      <.empty_state :if={@library && @skill_search_active? && @filtered_skill_count == 0}>
        No skills match "<%= @skill_search_query %>".
      </.empty_state>

      <%= if @skill_search_active? do %>
        <div :for={{category, clusters} <- @search_grouped} class="fw-collapse">
          <details open>
            <summary class="fw-collapse-summary">
              <span class="fw-collapse-arrow"></span>
              <span class="fw-cluster-title"><%= category %></span>
              <span class="badge-muted"><%= Enum.sum(Enum.map(clusters, fn {_, s} -> length(s) end)) %> skills</span>
            </summary>

            <div class="fw-collapse-body">
              <details :for={{cluster, cluster_skills} <- clusters} class="fw-collapse fw-collapse--nested" open>
                <summary class="fw-collapse-summary">
                  <span class="fw-collapse-arrow"></span>
                  <span class="fw-category-title"><%= cluster %></span>
                  <span class="badge-muted"><%= length(cluster_skills) %></span>
                </summary>

                <div class="fw-collapse-body">
                  <.skill_table skills={cluster_skills} highlight_skill={@highlight_skill} />
                </div>
              </details>
            </div>
          </details>
        </div>
      <% else %>
        <% raw_cats = Enum.map(@grouped_index || [], fn {_label, [{_, raw_cat, _, _} | _]} -> raw_cat end) %>
        <%= for {{category, clusters}, raw_cat} <- Enum.zip(@grouped_index || [], raw_cats) do %>
          <div class={"fw-collapse" <> if(MapSet.member?(@open_categories, raw_cat), do: " is-open", else: "")}>
            <button
              type="button"
              class="fw-collapse-summary"
              phx-click="toggle_category"
              phx-value-category={raw_cat || ""}
            >
              <span class="fw-collapse-arrow"></span>
              <span class="fw-cluster-title"><%= category %></span>
              <span class="badge-muted"><%= Enum.sum(Enum.map(clusters, fn {_, _, _, n} -> n end)) %> skills</span>
            </button>

            <div :if={MapSet.member?(@open_categories, raw_cat)} class="fw-collapse-body">
              <div
                :for={{cluster_label, raw_cat, raw_cluster, count} <- clusters}
                class={"fw-collapse fw-collapse--nested" <> if(MapSet.member?(@open_clusters, {raw_cat, raw_cluster}), do: " is-open", else: "")}
              >
                <button
                  type="button"
                  class="fw-collapse-summary"
                  phx-click="load_cluster"
                  phx-value-category={raw_cat || ""}
                  phx-value-cluster={raw_cluster || ""}
                >
                  <span class="fw-collapse-arrow"></span>
                  <span class="fw-category-title"><%= cluster_label %></span>
                  <span class="badge-muted"><%= count %></span>
                </button>

                <div :if={MapSet.member?(@open_clusters, {raw_cat, raw_cluster})} class="fw-collapse-body">
                  <%= case Map.get(@cluster_skills, {raw_cat, raw_cluster}) do %>
                    <% nil -> %>
                      <p class="cluster-loading">Loading…</p>
                    <% skills -> %>
                      <.skill_table skills={skills} highlight_skill={@highlight_skill} />
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      <% end %>
    </.page_shell>
    """
  end

  def roles(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Role Profiles" subtitle="Manage role profiles and skill requirements">
        <:actions>
          <.link patch={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-primary">
            + New Role Profile
          </.link>
        </:actions>
      </.page_header>

      <form phx-change="search_roles" phx-submit="search_roles" class="search-bar">
        <input
          type="search"
          name="q"
          value={@role_search_query}
          placeholder="Search across your roles + ESCO public catalog…"
          phx-debounce="300"
          class="search-input"
          autocomplete="off"
        />
        <span :if={@role_search_pending?} class="badge-muted">Refining…</span>
      </form>

      <%= if @role_search_results do %>
        <.empty_state :if={@role_search_results == []}>
          No matches for "<%= @role_search_query %>".
        </.empty_state>

        <div :if={@role_search_results != []} class="lib-list">
          <div class="lib-list-header">
            <span class="lib-col-name">Name</span>
            <span class="lib-col-version">Seniority</span>
            <span class="lib-col-skills">Skills</span>
            <span class="lib-col-updated">Family</span>
            <span class="lib-col-actions"></span>
          </div>

          <div :for={rp <- @role_search_results} class="lib-row lib-row-version">
            <span class="lib-col-name">
              <.link
                patch={~p"/orgs/#{@current_organization.slug}/roles/#{rp.id}"}
                class="lib-name-link"
              >
                <%= rp.name %>
              </.link>
              <span :if={rp.organization_id != @current_organization.id} class="badge-public">
                Public
              </span>
            </span>
            <span class="lib-col-version">
              <span :if={rp.seniority_label} class="badge-muted"><%= rp.seniority_label %></span>
            </span>
            <span class="lib-col-skills"><%= rp.skill_count %></span>
            <span class="lib-col-updated"><%= rp.role_family || "—" %></span>
            <span class="lib-col-actions"></span>
          </div>
        </div>
      <% else %>
        <.empty_state :if={@profiles == []}>
          No role profiles yet. Create one in the chat editor.
        </.empty_state>

        <div :if={@profiles != []} class="lib-list">
          <div class="lib-list-header">
            <span class="lib-col-name">Name</span>
            <span class="lib-col-version">Seniority</span>
            <span class="lib-col-skills">Skills</span>
            <span class="lib-col-updated">Updated</span>
            <span class="lib-col-actions"></span>
          </div>

          <%= for {family, family_profiles} <- @role_grouped do %>
            <details class="lib-group" open={length(@role_grouped) <= 3}>
              <summary class="lib-row lib-row-primary">
                <span class="lib-col-name">
                  <span class="lib-name-link"><%= family || "Ungrouped" %></span>
                  <span class="badge-muted"><%= length(family_profiles) %> roles</span>
                </span>
                <span class="lib-col-version"></span>
                <span class="lib-col-skills"></span>
                <span class="lib-col-updated"></span>
                <span class="lib-col-actions"></span>
              </summary>

              <%= for rp <- family_profiles do %>
                <div class="lib-row lib-row-version">
                  <span class="lib-col-name lib-version-indent">
                    <.link
                      patch={~p"/orgs/#{@current_organization.slug}/roles/#{rp.id}"}
                      class="lib-name-link"
                    >
                      <%= rp.name %>
                    </.link>
                    <span :if={rp.organization_id != @current_organization.id} class="badge-public">
                      Public
                    </span>
                  </span>
                  <span class="lib-col-version">
                    <span :if={rp.seniority_label} class="badge-muted"><%= rp.seniority_label %></span>
                  </span>
                  <span class="lib-col-skills"><%= rp.skill_count %></span>
                  <span class="lib-col-updated">
                    <%= Calendar.strftime(rp.updated_at, "%b %d, %Y %H:%M") %>
                  </span>
                  <span class="lib-col-actions">
                    <button
                      :if={rp.organization_id == @current_organization.id}
                      phx-click="delete_role"
                      phx-value-name={rp.name}
                      data-confirm={"Delete role profile '#{rp.name}'?"}
                      class="btn-danger-sm"
                    >
                      Delete
                    </button>
                  </span>
                </div>
              <% end %>
            </details>
          <% end %>
        </div>
      <% end %>
    </.page_shell>
    """
  end

  def role_show(assigns) do
    ~H"""
    <.page_shell>
      <div :if={@profile} class="breadcrumb">
        <.link patch={~p"/orgs/#{@current_organization.slug}/roles"}>Roles</.link>
        <span class="breadcrumb-sep">/</span>
        <span><%= @profile.name %></span>
      </div>

      <.page_header :if={@profile} title={@profile.name} subtitle={role_subtitle(@profile)}>
        <:actions>
          <.link patch={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-secondary">
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

          <details :for={{category, clusters} <- @role_skills_grouped} class="fw-collapse">
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
                        <td>
                          <.link patch={~p"/orgs/#{@current_organization.slug}/libraries/#{rs.skill.library_id}?skill=#{rs.skill.id}"} class="skill-link">
                            <%= rs.skill.name %>
                          </.link>
                        </td>
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

  def settings(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Organization Settings" subtitle={"Manage #{@current_organization.name}"}>
        <:actions>
          <.link patch={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-secondary">
            Back
          </.link>
        </:actions>
      </.page_header>

      <div class="form-card">
        <.form for={@org_changeset} phx-submit="save_org">
          <div class="form-group">
            <label for="org_name" class="form-label">Name</label>
            <input
              type="text"
              name="organization[name]"
              id="org_name"
              value={@org_changeset[:name].value}
              class="form-input"
              required
              maxlength="100"
            />
            <p :if={@org_changeset[:name].errors != []} class="form-error">
              <%= elem(hd(@org_changeset[:name].errors), 0) %>
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
            ><%= @org_changeset[:context].value %></textarea>
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

  def members(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Members" subtitle={"Manage members of #{@current_organization.name}"}>
        <:actions>
          <.link patch={~p"/orgs/#{@current_organization.slug}/chat"} class="btn-secondary">
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
                  phx-click="remove_member"
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

  def role_subtitle(profile) do
    parts =
      [profile.role_family, profile.seniority_label, profile.description]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    if parts == [] do
      nil
    else
      Enum.join(parts, " - ")
    end
  end

  def has_rich_fields?(profile) do
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

  attr(:skills, :list, required: true)
  attr(:highlight_skill, :string, default: nil)

  defp skill_table(assigns) do
    ~H"""
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
        <%= for skill <- @skills do %>
          <tr
            id={"skill-#{skill.id}"}
            class={"skill-row" <> if(@highlight_skill == skill.id, do: " skill-highlight", else: "")}
            onclick={"this.classList.toggle('skill-expanded');document.getElementById('prof-#{skill.id}').classList.toggle('proficiency-hidden')"}
            style="cursor: pointer;"
          >
            <td><span class="skill-expand-arrow"></span><%= skill.name %></td>
            <td><%= skill.description %></td>
            <td>
              <span class={"badge-#{skill.status}"}><%= skill.status %></span>
            </td>
            <td><%= length(skill.proficiency_levels || []) %></td>
          </tr>
          <tr :if={(skill.proficiency_levels || []) != []} id={"prof-#{skill.id}"} class="proficiency-hidden">
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
    """
  end
end
