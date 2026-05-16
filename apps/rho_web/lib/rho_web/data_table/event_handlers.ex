defmodule RhoWeb.DataTable.EventHandlers do
  @moduledoc false

  alias RhoWeb.DataTable.Events.ArtifactActions
  alias RhoWeb.DataTable.Events.Navigation
  alias RhoWeb.DataTable.Events.Rows
  alias RhoWeb.DataTable.Events.Selection

  @navigation_events ~w[
    select_tab
    close_tab
    show_workbench_home
    hide_workbench_home
    workbench_action_open
    workbench_library_open
    navigate_to_library
    candidates_done
  ]

  @selection_events ~w[
    toggle_row_selection
    toggle_all_selection
    clear_selection
  ]

  @artifact_action_events ~w[
    open_save_dialog
    open_publish_dialog
    open_suggest_dialog
    close_dialog
    noop
    dismiss_flash
    confirm_save
    confirm_publish
    confirm_suggest
    create_role_profile
    fork_library
    toggle_export_menu
    close_export_menu
    export_csv
    export_xlsx
  ]

  def handle_event(event, params, socket) when event in @navigation_events do
    Navigation.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @selection_events do
    Selection.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @artifact_action_events do
    ArtifactActions.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) do
    Rows.handle_event(event, params, socket)
  end
end
