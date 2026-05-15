defmodule RhoWeb.WorkbenchActionsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.WorkbenchActions

  test "home actions expose stable workflow starters" do
    actions = WorkbenchActions.home_actions()

    assert Enum.map(actions, & &1.id) == [
             :create_framework,
             :extract_jd,
             :import_library,
             :load_library,
             :find_roles
           ]

    assert Enum.map(actions, & &1.label) == [
             "Create Framework",
             "Extract JD",
             "Import Library",
             "Load Library",
             "Find Roles"
           ]

    assert Enum.all?(actions, &Map.has_key?(&1, :mode))
    assert Enum.all?(actions, &Map.has_key?(&1, :execution))
    assert WorkbenchActions.get("create_framework").execution == :agent_prompt
  end
end
