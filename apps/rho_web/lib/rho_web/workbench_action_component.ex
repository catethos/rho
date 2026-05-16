defmodule RhoWeb.WorkbenchActionComponent do
  @moduledoc """
  Function components for Workbench home actions and action modals.
  """

  use Phoenix.Component

  attr(:actions, :list, required: true)
  attr(:target, :any, default: nil)
  attr(:agent_name, :any, default: nil)
  attr(:libraries, :list, default: [])
  attr(:chat_mode, :atom, default: nil)
  attr(:return_available?, :boolean, default: false)

  def workbench_home(assigns) do
    library_action_ids = [:create_framework, :extract_jd, :import_library, :create_role_profile]

    assigns =
      assigns
      |> assign(:library_actions, Enum.filter(assigns.actions, &(&1.id in library_action_ids)))
      |> assign(:assistant_state, assistant_state(assigns.agent_name))
      |> assign(:library_count, length(assigns.libraries || []))
      |> assign(:skill_count, total_skill_count(assigns.libraries || []))
      |> assign(:library_list, assigns.libraries || [])

    ~H"""
    <section class="workbench-home" aria-label="Workbench home">
      <div class="workbench-home-shell">
        <div class="workbench-home-hero">
          <div class="workbench-home-copy">
            <p class="workbench-home-kicker">Workbench</p>
            <h2>Start a skills project from what you already have.</h2>
            <p class="workbench-home-lede">
              Open a saved library, or start a new one from a brief, job description, or spreadsheet import.
            </p>
            <div class="workbench-utility-row">
              <div class="workbench-agent-state">
                <span class={"workbench-state-dot #{state_class(@assistant_state)}"}></span>
                <span><%= assistant_state_copy(@assistant_state, @agent_name) %></span>
              </div>
              <button
                type="button"
                class="workbench-chat-toggle"
                phx-click="toggle_chat"
                title={chat_action_title(@chat_mode)}
              >
                <%= chat_action_label(@chat_mode) %>
              </button>
            </div>
            <button
              :if={@return_available?}
              type="button"
              class="workbench-return-btn"
              phx-click="hide_workbench_home"
              phx-target={@target}
            >
              Back to current work
            </button>
          </div>

        </div>

        <div class="workbench-status-panel" aria-label="Organization status">
          <div class="workbench-status-header">
            <div class="workbench-status-title">
              <p class="workbench-home-kicker">Library browser</p>
              <div class="workbench-title-row">
                <h3><%= status_title(@library_count) %></h3>
                <details id="workbench-library-create-menu" class="workbench-library-create-menu" phx-hook="CloseDetailsOnOutsideClick">
                  <summary title="Create a library" aria-label="Create a library">+</summary>
                  <div class="workbench-library-create-popover" role="menu">
                    <button
                      :for={action <- @library_actions}
                      type="button"
                      class={[
                        "workbench-library-source-btn",
                        if(action_available?(action, @assistant_state), do: "", else: "is-disabled")
                      ]}
                      phx-click="workbench_action_open"
                      phx-target={@target}
                      phx-value-action={action.id}
                      disabled={!action_available?(action, @assistant_state)}
                      title={action_title(action, @assistant_state)}
                      role="menuitem"
                    >
                      <span><%= library_action_label(action.id) %></span>
                    </button>
                  </div>
                </details>
              </div>
            </div>
            <div class="workbench-status-metrics">
              <span><strong><%= @library_count %></strong> libraries</span>
              <span><strong><%= @skill_count %></strong> skills</span>
            </div>
          </div>

          <div :if={@library_list != []} class="workbench-library-list">
            <button
              :for={library <- @library_list}
              type="button"
              class="workbench-library-row"
              phx-click="workbench_library_open"
              phx-target={@target}
              phx-value-library-id={library_id(library)}
            >
              <span class="workbench-library-main">
                <span class="workbench-library-name"><%= library.name %></span>
                <span class="workbench-library-meta"><%= library_meta(library) %></span>
              </span>
              <span class="workbench-library-open">Open</span>
            </button>
          </div>

          <p :if={@library_list == []} class="workbench-empty-note">
            No saved libraries yet. Create or import the first framework with the Spreadsheet assistant.
          </p>
        </div>

      </div>
    </section>
    """
  end

  defp library_action_label(:create_framework), do: "Create from brief"
  defp library_action_label(:extract_jd), do: "Create from JD"
  defp library_action_label(:import_library), do: "Import spreadsheet"
  defp library_action_label(:create_role_profile), do: "Create role"
  defp library_action_label(_), do: "Start"

  defp assistant_state(agent_name) when agent_name in [:spreadsheet, "spreadsheet"],
    do: :spreadsheet

  defp assistant_state(nil), do: :empty
  defp assistant_state(_), do: :other

  defp state_class(:spreadsheet), do: "is-ready"
  defp state_class(:empty), do: "is-open"
  defp state_class(:other), do: "is-limited"

  defp assistant_state_copy(:spreadsheet, _agent_name) do
    "Spreadsheet assistant is active. Agent-assisted workflows are ready."
  end

  defp assistant_state_copy(:empty, _agent_name) do
    "No assistant is active yet. Agent-assisted workflows will start Spreadsheet."
  end

  defp assistant_state_copy(:other, agent_name) do
    "Current assistant: #{display_agent_name(agent_name)}. Agent-assisted workflows need Spreadsheet."
  end

  defp action_available?(%{execution: :direct}, _assistant_state), do: true
  defp action_available?(_action, :other), do: false
  defp action_available?(_action, _assistant_state), do: true

  defp action_title(action, assistant_state) do
    if action_available?(action, assistant_state) do
      action.summary
    else
      "Switch to the Spreadsheet assistant to use this workflow."
    end
  end

  defp display_agent_name(nil), do: "none selected"

  defp display_agent_name(agent_name) do
    agent_name
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp total_skill_count(libraries) do
    Enum.reduce(libraries, 0, fn library, acc -> acc + (Map.get(library, :skill_count) || 0) end)
  end

  defp status_title(0), do: "Blank slate"
  defp status_title(1), do: "1 framework on hand"
  defp status_title(count), do: "#{count} frameworks on hand"

  defp library_meta(library) do
    version = if library.version, do: "v#{library.version}", else: "draft"
    immutable = if library.immutable, do: ", immutable", else: ""
    "#{library.skill_count} skills, #{version}#{immutable}"
  end

  defp library_id(library), do: Map.get(library, :id)

  defp chat_action_label(:expanded), do: "Hide Assistant Chat"
  defp chat_action_label(_), do: "Open Assistant Chat"

  defp chat_action_title(:expanded), do: "Hide the assistant chat panel."
  defp chat_action_title(_), do: "Show the assistant chat panel."

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

            <% :create_role_profile -> %>
              <.text_input name="role_name" label="Role name" value={@form["role_name"]} required />
              <div class="workbench-picker">
                <label class="workbench-field">
                  <span>Source library</span>
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
              <.modal_actions busy?={@busy?} label="Create Role" />

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
