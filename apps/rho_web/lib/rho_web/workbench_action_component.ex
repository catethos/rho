defmodule RhoWeb.WorkbenchActionComponent do
  @moduledoc """
  Function components for Workbench home actions and action modals.
  """

  use Phoenix.Component

  attr(:actions, :list, required: true)
  attr(:target, :any, default: nil)

  def workbench_home(assigns) do
    primary = Enum.find(assigns.actions, &(&1.id == :create_framework))
    secondary = Enum.reject(assigns.actions, &(&1.id == :create_framework))
    assigns = assign(assigns, primary_action: primary, secondary_actions: secondary)

    ~H"""
    <section class="workbench-home" aria-label="Workbench home">
      <div class="workbench-home-shell">
        <div class="workbench-home-hero">
          <div class="workbench-home-copy">
            <p class="workbench-home-kicker">Workbench</p>
            <h2>Start a skills project from what you already have.</h2>
            <p class="workbench-home-lede">
              Create a skill framework from a brief, turn a job description into role requirements, import a spreadsheet, or open existing work.
            </p>
          </div>

          <button
            :if={@primary_action}
            type="button"
            class="workbench-primary-action"
            phx-click="workbench_action_open"
            phx-target={@target}
            phx-value-action={@primary_action.id}
          >
            <span class="workbench-action-eyebrow">Start here</span>
            <span class="workbench-primary-label"><%= @primary_action.label %></span>
            <span class="workbench-primary-summary"><%= @primary_action.summary %></span>
          </button>
        </div>

        <div class="workbench-home-body">
          <div class="workbench-action-grid">
            <button
              :for={action <- @secondary_actions}
              type="button"
              class="workbench-action-card"
              phx-click="workbench_action_open"
              phx-target={@target}
              phx-value-action={action.id}
            >
              <span class="workbench-action-index"><%= action_index(action.id) %></span>
              <span class="workbench-action-label"><%= action.label %></span>
              <span class="workbench-action-summary"><%= action.summary %></span>
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp action_index(:extract_jd), do: "01"
  defp action_index(:import_library), do: "02"
  defp action_index(:load_library), do: "03"
  defp action_index(:find_roles), do: "04"
  defp action_index(_), do: "--"

  attr(:action, :map, default: nil)
  attr(:form, :map, default: %{})
  attr(:error, :string, default: nil)
  attr(:busy?, :boolean, default: false)
  attr(:libraries, :list, default: [])
  attr(:uploads, :map, default: %{})
  attr(:org_slug, :string, default: nil)

  def action_modal(%{action: nil} = assigns), do: ~H""

  def action_modal(assigns) do
    assigns = assign(assigns, :action_id, assigns.action.id)

    ~H"""
    <div class="workbench-modal-backdrop">
      <div class="workbench-modal" phx-click-away="workbench_action_cancel">
        <div class="workbench-modal-header">
          <div>
            <p class="workbench-modal-kicker">Workbench action</p>
            <h3><%= @action.label %></h3>
            <p><%= @action.summary %></p>
          </div>
          <button type="button" class="workbench-modal-close" phx-click="workbench_action_cancel" title="Close">
            &times;
          </button>
        </div>

        <div :if={@error} class="workbench-modal-error"><%= @error %></div>

        <form phx-submit="workbench_action_submit" phx-change="workbench_action_change" class="workbench-modal-form">
          <input type="hidden" name="action" value={@action.id} />
          <%= case @action_id do %>
            <% :create_framework -> %>
              <.text_input name="name" label="Framework name" value={@form["name"]} required />
              <.text_area name="description" label="Description" value={@form["description"]} rows="3" />
              <.text_input name="domain" label="Domain" value={@form["domain"]} />
              <.text_input name="target_roles" label="Target roles" value={@form["target_roles"]} />
              <.text_input name="skill_count" label="Skill count" value={@form["skill_count"] || "12"} type="number" min="1" max="80" />
              <.modal_actions busy?={@busy?} label="Create Framework">
                <:secondary :if={@org_slug}>
                  <a class="workbench-secondary-link" href={"/orgs/#{@org_slug}/flows/create-framework"}>Open Guided Flow</a>
                </:secondary>
              </.modal_actions>

            <% :extract_jd -> %>
              <.upload_input uploads={@uploads} />
              <.text_area name="text" label="Paste job description" value={@form["text"]} rows="6" />
              <.text_input name="role_name" label="Role name" value={@form["role_name"]} />
              <.text_input name="library_name" label="Library name" value={@form["library_name"]} />
              <.modal_actions busy?={@busy?} label="Extract JD" />

            <% :import_library -> %>
              <.upload_input uploads={@uploads} />
              <.text_input name="library_name" label="Library name" value={@form["library_name"]} />
              <.text_input name="sheet" label="Sheet" value={@form["sheet"]} />
              <.modal_actions busy?={@busy?} label="Import Library" />

            <% :load_library -> %>
              <div class="workbench-picker">
                <label class="workbench-field">
                  <span>Saved library</span>
                  <select name="library_id" required>
                    <option value="">Choose a library</option>
                    <option
                      :for={library <- @libraries}
                      value={library.id}
                      selected={to_string(library.id) == to_string(@form["library_id"] || "")}
                    >
                      <%= library_option_label(library) %>
                    </option>
                  </select>
                </label>
              </div>
              <.modal_actions busy?={@busy?} label="Load Library" />

            <% :find_roles -> %>
              <.text_area name="queries" label="Role names or search queries" value={@form["queries"]} rows="4" required />
              <.text_input name="library_id" label="Library filter" value={@form["library_id"]} />
              <.text_input name="limit" label="Limit" value={@form["limit"] || "10"} type="number" min="1" max="25" />
              <.modal_actions busy?={@busy?} label="Find Roles" />
          <% end %>
        </form>
      </div>
    </div>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:type, :string, default: "text")
  attr(:required, :boolean, default: false)
  attr(:min, :string, default: nil)
  attr(:max, :string, default: nil)

  defp text_input(assigns) do
    ~H"""
    <label class="workbench-field">
      <span><%= @label %></span>
      <input
        type={@type}
        name={@name}
        value={@value}
        required={@required}
        min={@min}
        max={@max}
      />
    </label>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:rows, :string, default: "4")
  attr(:required, :boolean, default: false)

  defp text_area(assigns) do
    ~H"""
    <label class="workbench-field">
      <span><%= @label %></span>
      <textarea name={@name} rows={@rows} required={@required}><%= @value %></textarea>
    </label>
    """
  end

  attr(:uploads, :map, required: true)

  defp upload_input(assigns) do
    entries = assigns.uploads.files.entries
    file_summary = Enum.map_join(entries, ", ", & &1.client_name)

    assigns =
      assigns
      |> assign(:has_files?, entries != [])
      |> assign(:file_summary, file_summary)

    ~H"""
    <div class="workbench-field">
      <span>File</span>
      <div class="workbench-file-picker">
        <.live_file_input id="workbench-file-upload" upload={@uploads.files} class="sr-only" />
        <label for="workbench-file-upload" class="workbench-file-button">Choose files</label>
        <div class="workbench-file-summary">
          <%= if @has_files?, do: @file_summary, else: "No files selected" %>
        </div>
      </div>
    </div>
    """
  end

  attr(:busy?, :boolean, default: false)
  attr(:label, :string, required: true)
  slot(:secondary)

  defp modal_actions(assigns) do
    ~H"""
    <div class="workbench-modal-actions">
      <button type="button" class="workbench-btn-secondary" phx-click="workbench_action_cancel">
        Cancel
      </button>
      <%= render_slot(@secondary) %>
      <button type="submit" class="workbench-btn-primary" disabled={@busy?}>
        <%= if @busy?, do: "Working...", else: @label %>
      </button>
    </div>
    """
  end

  defp library_option_label(library) do
    version =
      cond do
        not is_nil(library.version) -> " v#{library.version}"
        library.immutable -> ""
        true -> " draft"
      end

    library.name <> version
  end
end
