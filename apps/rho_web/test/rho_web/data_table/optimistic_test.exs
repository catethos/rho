defmodule RhoWeb.DataTable.OptimisticTest do
  use ExUnit.Case, async: true

  alias RhoWeb.DataTable.Optimistic

  describe "apply/2" do
    test "overlays top-level edits while preserving existing atom keys" do
      rows = [%{id: "row-1", name: "Old"}, %{"id" => "row-2", "name" => "Other"}]

      optimistic = %{
        {"row-1", nil, "name"} => "New",
        {"row-2", nil, "name"} => "Changed"
      }

      assert Optimistic.apply(rows, optimistic) == [
               %{id: "row-1", name: "New"},
               %{"id" => "row-2", "name" => "Changed"}
             ]
    end

    test "adds unknown string fields without creating atoms" do
      [row] = Optimistic.apply([%{id: "row-1"}], %{{"row-1", nil, "brand_new"} => "value"})

      assert row["brand_new"] == "value"
      refute Map.has_key?(row, :brand_new)
    end

    test "overlays child edits for atom and string children keys" do
      atom_row = %{
        id: "skill-1",
        proficiency_levels: [%{level_name: "Aware"}, %{level_name: "Builds"}]
      }

      string_row = %{
        "id" => "skill-2",
        "proficiency_levels" => [%{"level_name" => "Aware"}]
      }

      optimistic = %{
        {"skill-1", 1, "level_name"} => "Leads",
        {"skill-2", 0, "level_name"} => "Knows"
      }

      assert Optimistic.apply([atom_row, string_row], optimistic) == [
               %{
                 id: "skill-1",
                 proficiency_levels: [%{level_name: "Aware"}, %{level_name: "Leads"}]
               },
               %{
                 "id" => "skill-2",
                 "proficiency_levels" => [%{"level_name" => "Knows"}]
               }
             ]
    end

    test "ignores edits for other rows" do
      rows = [%{id: "row-1", name: "Old"}]

      assert Optimistic.apply(rows, %{{"row-2", nil, "name"} => "New"}) == rows
    end
  end
end
