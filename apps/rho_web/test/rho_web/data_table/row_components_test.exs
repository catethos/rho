defmodule RhoWeb.DataTable.RowComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RhoWeb.DataTable.RowComponents
  alias RhoWeb.DataTable.Schema.Column

  test "parent_row renders provenance, editable cells, selection, and delete controls" do
    html =
      render_component(&RowComponents.parent_row/1,
        dom_id: "row-1",
        row: %{id: "1", _source: :agent, skill_name: "Elixir"},
        visible_columns: [%Column{key: :skill_name, label: "Skill", editable: true}],
        child_columns: [],
        children_key: nil,
        show_id: true,
        has_children: false,
        panel_mode: false,
        editing: nil,
        myself: "component-id",
        collapsed: MapSet.new(),
        metadata: %{},
        confirm_delete: nil,
        selected_ids: MapSet.new(["1"])
      )

    assert html =~ "dt-row-selected"
    assert html =~ "Elixir"
    assert html =~ "Written by agent"
    assert html =~ ~s(phx-click="confirm_delete")
  end

  test "proficiency_panel_row renders children in level order with inline edit hooks" do
    html =
      render_component(&RowComponents.proficiency_panel_row/1,
        dom_id: "panel-1",
        row: %{
          id: "1",
          proficiency_levels: [
            %{level: 2, level_name: "Builds", level_description: "Can build"},
            %{level: 1, level_name: "Aware", level_description: "Knows basics"}
          ]
        },
        children_key: :proficiency_levels,
        editing: nil,
        myself: "component-id",
        panel_colspan: 6
      )

    assert html =~ "panel-1"
    assert html =~ "L1"
    assert html =~ "Aware"
    assert html =~ "L2"
    assert html =~ "Builds"
    assert html =~ ~s(phx-click="add_child")
  end

  test "add_row_in_group carries one-level and two-level group values" do
    html =
      render_component(&RowComponents.add_row_in_group/1,
        myself: "component-id",
        group_by: [:category, :cluster],
        group_label: "Engineering",
        sub_label: "Backend"
      )

    assert html =~ ~s(phx-click="add_row")
    assert html =~ ~s(phx-value-category="Engineering")
    assert html =~ ~s(phx-value-cluster="Backend")
  end
end
