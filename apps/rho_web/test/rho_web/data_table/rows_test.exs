defmodule RhoWeb.DataTable.RowsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.DataTable.Rows

  describe "sort/3" do
    test "sorts strings case-insensitively using atom or string keys" do
      rows = [
        %{id: "2", name: "beta"},
        %{"id" => "1", "name" => "Alpha"},
        %{id: "3", name: "charlie"}
      ]

      assert Rows.sort(rows, :name, :asc) |> Enum.map(&Rows.row_id/1) == ["1", "2", "3"]
      assert Rows.sort(rows, "name", :desc) |> Enum.map(&Rows.row_id/1) == ["3", "2", "1"]
    end

    test "keeps row order when no sort field is selected" do
      rows = [%{id: "2"}, %{id: "1"}]

      assert Rows.sort(rows, nil, :desc) == rows
    end
  end

  describe "group/2" do
    test "returns an all group when no grouping fields are configured" do
      rows = [%{id: "1"}]

      assert Rows.group(rows, []) == [{"All", {:rows, rows}}]
    end

    test "groups by one field preserving first-seen group and row order" do
      rows = [
        %{id: "1", category: "Core"},
        %{id: "2", category: "Advanced"},
        %{id: "3", category: "Core"}
      ]

      [core_first, advanced, core_second] = rows

      assert Rows.group(rows, [:category]) == [
               {"Core", {:rows, [core_first, core_second]}},
               {"Advanced", {:rows, [advanced]}}
             ]
    end

    test "groups by two fields with atom and string row keys" do
      rows = [
        %{id: "1", category: "Core", cluster: "A"},
        %{"id" => "2", "category" => "Core", "cluster" => "B"},
        %{id: "3", category: "Advanced", cluster: "A"}
      ]

      [core_a, core_b, advanced_a] = rows

      assert Rows.group(rows, [:category, :cluster]) == [
               {"Core", {:nested, [{"A", [core_a]}, {"B", [core_b]}]}},
               {"Advanced", {:nested, [{"A", [advanced_a]}]}}
             ]
    end
  end

  test "collect_group_ids/1 includes top-level and nested group ids" do
    grouped = [
      {"Core", {:nested, [{"Level 1", [%{id: "1"}]}, {"Level 2", [%{id: "2"}]}]}},
      {"Advanced", {:rows, [%{id: "3"}]}}
    ]

    assert Rows.collect_group_ids(grouped) ==
             MapSet.new(["grp-core", "grp-core-level-1", "grp-core-level-2", "grp-advanced"])
  end

  test "count_nested_rows/1 counts flat and nested grouped rows" do
    assert Rows.count_nested_rows({:rows, [%{}, %{}]}) == 2
    assert Rows.count_nested_rows({:nested, [{"A", [%{}]}, {"B", [%{}, %{}]}]}) == 3
  end

  describe "selection helpers" do
    test "visible_row_ids/1 preserves order and skips rows without ids" do
      assert Rows.visible_row_ids([%{id: 1}, %{}, %{"id" => "2"}]) == ["1", "2"]
      assert Rows.visible_row_ids(nil) == []
    end

    test "select_all_state/2 reports none, some, and all" do
      rows = [%{id: "1"}, %{id: "2"}]

      assert Rows.select_all_state(rows, MapSet.new()) == :none
      assert Rows.select_all_state(rows, MapSet.new(["1"])) == :some
      assert Rows.select_all_state(rows, MapSet.new(["1", "2", "3"])) == :all
      assert Rows.select_all_state([], MapSet.new(["1"])) == :none
      assert Rows.select_all_state(rows, nil) == :none
    end
  end
end
