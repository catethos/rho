defmodule RhoWeb.DataTable.CommandsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.DataTable.Commands
  alias RhoWeb.DataTable.Schema
  alias RhoWeb.DataTable.Schema.Column

  describe "cell_change/5" do
    test "builds a top-level cell update and optimistic key" do
      rows = [%{id: "row-1", name: "Old"}]
      schema = schema([column(:name, "Name")])

      assert Commands.cell_change(rows, schema, "row-1", "name", "New") ==
               {%{"id" => "row-1", "field" => "name", "value" => "New"}, {"row-1", nil, "name"}}
    end

    test "builds child updates using natural child key fields" do
      schema = %Schema{
        columns: [column(:skill_name, "Skill")],
        children_key: :proficiency_levels,
        child_key_fields: [:level],
        child_columns: [column(:level, "Level", :number), column(:description, "Description")]
      }

      rows = [
        %{
          id: "skill-1",
          skill_name: "Elixir",
          proficiency_levels: [
            %{level: 1, description: "Aware"},
            %{level: 2, description: "Builds"}
          ]
        }
      ]

      assert Commands.cell_change(rows, schema, "skill-1:child:1", "description", "Leads") ==
               {%{
                  "id" => "skill-1",
                  "child_key" => %{"level" => 2},
                  "field" => "description",
                  "value" => "Leads"
                }, {"skill-1", 1, "description"}}
    end
  end

  test "group_edit_changes/4 updates matching rows without dynamic atom creation" do
    rows = [
      %{id: "1", category: "Engineering"},
      %{"id" => "2", "category" => "Product"},
      %{id: "3", category: "Engineering"}
    ]

    assert Commands.group_edit_changes(rows, "category", "Engineering", "Delivery") == [
             %{"id" => "1", "field" => "category", "value" => "Delivery"},
             %{"id" => "3", "field" => "category", "value" => "Delivery"}
           ]

    assert Commands.group_edit_changes(rows, "not_a_known_atom", "Engineering", "Delivery") == []
  end

  test "new_row/2 uses visible placeholders and optional group values" do
    schema = schema([column(:skill_name, "Skill"), column(:score, "Score", :number)])

    assert Commands.new_row(schema, %{"category" => "Tech"}) == %{
             skill_name: "(new)",
             score: 0,
             category: "Tech"
           }
  end

  test "add_child_change/3 appends the next child level and handles empty child lists" do
    schema = %Schema{
      columns: [column(:skill_name, "Skill")],
      children_key: :proficiency_levels,
      child_columns: [column(:level, "Level", :number), column(:description, "Description")]
    }

    rows = [%{id: "skill-1", proficiency_levels: [%{level: 2, description: "Builds"}]}]

    assert Commands.add_child_change(rows, schema, "skill-1") == %{
             "id" => "skill-1",
             "field" => "proficiency_levels",
             "value" => [%{level: 2, description: "Builds"}, %{level: 3, description: ""}]
           }

    assert Commands.add_child_change(
             [%{id: "skill-2", proficiency_levels: []}],
             schema,
             "skill-2"
           )[
             "value"
           ] == [%{level: 1, description: ""}]
  end

  test "delete_child_change/4 removes a child by rendered index" do
    schema = %Schema{children_key: :proficiency_levels}

    rows = [%{id: "skill-1", proficiency_levels: [%{level: 1}, %{level: 2}]}]

    assert Commands.delete_child_change(rows, schema, "skill-1", "0") == %{
             "id" => "skill-1",
             "field" => "proficiency_levels",
             "value" => [%{level: 2}]
           }
  end

  defp schema(columns), do: %Schema{title: "Data", columns: columns}

  defp column(key, label, type \\ :text) do
    %Column{key: key, label: label, type: type}
  end
end
