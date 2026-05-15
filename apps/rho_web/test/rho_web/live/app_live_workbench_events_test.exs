defmodule RhoWeb.AppLiveWorkbenchEventsTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias RhoWeb.AppLive.WorkbenchEvents
  alias RhoWeb.WorkbenchActions

  test "default_form/1 provides expected modal defaults" do
    assert WorkbenchEvents.default_form(:create_framework) == %{"skill_count" => "12"}
    assert WorkbenchEvents.default_form(:find_roles) == %{"limit" => "10"}
    assert WorkbenchEvents.default_form(:load_library) == %{}
  end

  test "normalize_params/1 strips LiveView and action envelope keys" do
    assert WorkbenchEvents.normalize_params(%{
             "_target" => ["name"],
             "action" => "create_framework",
             "name" => "Platform Skills",
             "skill_count" => "18"
           }) == %{"name" => "Platform Skills", "skill_count" => "18"}
  end

  test "action_id/1 reads action params safely" do
    assert WorkbenchEvents.action_id(%{"action" => "find_roles"}) == "find_roles"
    assert WorkbenchEvents.action_id(%{}) == nil
  end

  test "accepted_upload?/2 constrains file-backed workbench actions" do
    assert WorkbenchEvents.accepted_upload?(:extract_jd, "role.docx")
    assert WorkbenchEvents.accepted_upload?(:extract_jd, "notes.md")
    refute WorkbenchEvents.accepted_upload?(:extract_jd, "skills.csv")

    assert WorkbenchEvents.accepted_upload?(:import_library, "skills.csv")
    assert WorkbenchEvents.accepted_upload?(:import_library, "skills.xlsx")
    refute WorkbenchEvents.accepted_upload?(:import_library, "brief.pdf")

    assert WorkbenchEvents.accepted_upload?(:create_framework, "anything.bin")
  end

  test "close_action/1 resets modal state without touching other assigns" do
    socket =
      %Socket{
        assigns: %{
          __changed__: %{},
          workbench_action_modal: WorkbenchActions.get("create_framework"),
          workbench_action_form: %{"name" => "Draft"},
          workbench_action_error: "Nope",
          workbench_action_busy?: true,
          untouched: :kept
        }
      }

    socket = WorkbenchEvents.close_action(socket)

    assert socket.assigns.workbench_action_modal == nil
    assert socket.assigns.workbench_action_form == %{}
    assert socket.assigns.workbench_action_error == nil
    assert socket.assigns.workbench_action_busy? == false
    assert socket.assigns.untouched == :kept
  end
end
