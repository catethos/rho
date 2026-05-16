defmodule RhoWeb.DataTableArtifactHeaderComponent do
  @moduledoc false

  use Phoenix.Component

  alias RhoWeb.DataTable.Artifacts

  attr(:active_artifact, :any, default: nil)
  attr(:active_table, :string, default: "main")
  attr(:export_menu_open, :boolean, default: false)
  attr(:flash_message, :string, default: nil)
  attr(:mode_label, :string, default: nil)
  attr(:myself, :any, required: true)
  attr(:rows, :list, default: [])
  attr(:schema, :map, required: true)
  attr(:streaming, :boolean, default: false)
  attr(:total_cost, :float, default: 0.0)
  attr(:view_key, :any, default: nil)

  def header(assigns) do
    ~H"""
    <div class="dt-artifact-header">
      <div class="dt-artifact-main">
        <div class="dt-artifact-kicker">
          <%= Artifacts.kind_label(@active_artifact, @schema.title) %>
        </div>
        <h2 class="dt-title"><%= Artifacts.title(@active_artifact, @schema.title) %></h2>
        <div class="dt-artifact-subtitle">
          <span><%= Artifacts.subtitle(@active_artifact, @mode_label) %></span>
          <span
            :if={@active_artifact && @active_artifact.source_label}
            class="dt-artifact-source"
          >
            <%= @active_artifact.source_label %>
          </span>
        </div>
        <div class="dt-metric-strip">
          <span
            :for={metric <- Artifacts.metric_labels(@active_artifact, length(@rows))}
            class="dt-metric-pill"
          >
            <%= metric %>
          </span>
          <span :if={@streaming} class="dt-streaming">
            streaming...
          </span>
          <span :if={@total_cost > 0} class="dt-cost">
            $<%= :erlang.float_to_binary(@total_cost / 1, decimals: 4) %>
          </span>
        </div>
      </div>

      <span
        :if={@flash_message}
        id={"dt-flash-" <> Integer.to_string(:erlang.phash2(@flash_message))}
        class={["dt-flash", progress_flash?(@flash_message) && "dt-flash-progress"]}
      >
        <span class="dt-flash-text"><%= @flash_message %></span>
        <span :if={progress_flash?(@flash_message)} class="dt-progress-track" aria-hidden="true">
          <span class="dt-progress-bar"></span>
        </span>
        <button
          type="button"
          class="dt-flash-close"
          phx-click="dismiss_flash"
          phx-target={@myself}
          title="Dismiss"
        >&times;</button>
      </span>

      <div class="dt-toolbar-actions">
        <button
          type="button"
          class="dt-action-btn dt-actions-hub-btn"
          phx-click="show_workbench_home"
          phx-target={@myself}
          title="Show Workbench actions"
        >
          Actions
        </button>
        <button
          :if={Artifacts.candidates_view?(@view_key, @active_table)}
          type="button"
          class="dt-action-btn dt-candidates-done-btn"
          phx-click="candidates_done"
          phx-target={@myself}
          title="Use the checked rows to seed a new framework"
        >
          ✓ Done — Seed Framework
        </button>
        <button
          :if={Artifacts.library_view?(@view_key, @active_table) || role_profile_view?(@active_artifact, @view_key, @active_table)}
          type="button"
          class="dt-action-btn dt-save-btn"
          phx-click="open_save_dialog"
          phx-target={@myself}
          title={if(role_profile_view?(@active_artifact, @view_key, @active_table), do: "Save role profile", else: "Save to library")}
        >
          Save
        </button>
        <button
          :if={Artifacts.library_view?(@view_key, @active_table)}
          type="button"
          class="dt-action-btn dt-publish-btn"
          phx-click="open_publish_dialog"
          phx-target={@myself}
          title="Publish as immutable version"
        >
          Publish
        </button>
        <button
          :if={Artifacts.library_view?(@view_key, @active_table)}
          type="button"
          class="dt-action-btn dt-fork-btn"
          phx-click="fork_library"
          phx-target={@myself}
          title="Fork as new library"
        >
          Fork
        </button>
        <button
          :if={Artifacts.library_view?(@view_key, @active_table)}
          type="button"
          class="dt-action-btn dt-suggest-btn"
          phx-click="open_suggest_dialog"
          phx-target={@myself}
          title="Ask the model for additional skills"
        >
          Suggest
        </button>
        <button
          :if={Artifacts.library_view?(@view_key, @active_table)}
          type="button"
          class="dt-action-btn dt-create-role-btn"
          phx-click="create_role_profile"
          phx-target={@myself}
          title="Create role requirements from this library"
        >
          Create Role
        </button>
        <div
          class="dt-export-dropdown"
          id={"dt-export-" <> (@active_table || "main")}
          phx-hook="ExportDownload"
        >
          <button
            type="button"
            class="dt-action-btn dt-export-btn"
            phx-click="toggle_export_menu"
            phx-target={@myself}
          >
            Export &#9662;
          </button>
          <div class={"dt-export-menu" <> if(@export_menu_open, do: " dt-export-menu-open", else: "")}>
            <button
              type="button"
              class="dt-export-option"
              phx-click="export_csv"
              phx-target={@myself}
            >
              CSV (.csv)
            </button>
            <button
              type="button"
              class="dt-export-option"
              phx-click="export_xlsx"
              phx-target={@myself}
            >
              Excel (.xlsx)
            </button>
          </div>
        </div>
        <button
          type="button"
          class="dt-action-btn dt-add-row-btn"
          phx-click="add_row"
          phx-target={@myself}
          title="Add row"
        >
          + Add Row
        </button>
      </div>
    </div>
    """
  end

  defp role_profile_view?(artifact, view_key, active_table) do
    view_key in [:role_profile, "role_profile"] or active_table == "role_profile" or
      (artifact && artifact.kind == :role_profile)
  end

  defp progress_flash?(message) when is_binary(message) do
    message = String.downcase(message)
    String.contains?(message, "saving") or String.contains?(message, "publishing")
  end

  defp progress_flash?(_message), do: false
end
