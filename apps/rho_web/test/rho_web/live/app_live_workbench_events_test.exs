defmodule RhoWeb.AppLiveWorkbenchEventsTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias Rho.Stdlib.DataTable
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

  test "create framework action starts a chat-hosted flow instead of sending a prompt" do
    sid = "workbench_flow_test_#{System.unique_integer([:positive])}"
    agent_id = Rho.Agent.Primary.agent_id(sid)
    on_exit(fn -> DataTable.stop(sid) end)

    socket = %Socket{
      assigns: %{
        __changed__: %{},
        session_id: sid,
        active_agent_id: agent_id,
        agent_messages: %{agent_id => []},
        next_id: 1,
        active_page: :chat,
        active_flow: nil,
        current_organization: %{id: Ecto.UUID.generate(), slug: "acme"},
        current_user: %{id: Ecto.UUID.generate()},
        workbench_action_modal: WorkbenchActions.get("create_framework"),
        workbench_action_form: %{"name" => "Platform Skills"},
        workbench_action_error: nil,
        workbench_action_busy?: false
      }
    }

    {:noreply, socket} =
      WorkbenchEvents.run_action(socket, %{id: :create_framework}, %{
        "name" => "Platform Skills",
        "description" => "Platform engineering skills",
        "taxonomy_size" => "compact"
      })

    assert socket.assigns.active_flow.id == "create-framework"
    assert socket.assigns.active_flow.runner.intake[:name] == "Platform Skills"
    assert socket.assigns.active_flow.runner.intake[:starting_point] == "scratch"
    assert [%{type: :flow_card}] = socket.assigns.agent_messages[agent_id]
    assert socket.assigns.workbench_action_modal == nil
  end
end
