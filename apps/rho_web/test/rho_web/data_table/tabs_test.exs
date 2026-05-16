defmodule RhoWeb.DataTable.TabsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.DataTable.Tabs

  test "display_order/2 hides empty default main when artifact tables exist" do
    tables = [%{name: "main", row_count: 0}, %{name: "library:skills", row_count: 3}]

    assert Tabs.display_order(["main", "library:skills"], tables) == ["library:skills"]
  end

  test "display_order/2 hides framework plumbing tables" do
    tables = [
      %{name: "meta", row_count: 1},
      %{name: "library:skills", row_count: 3},
      %{name: "library:leadership", row_count: 2}
    ]

    assert Tabs.display_order(["meta", "library:skills", "library:leadership"], tables) == [
             "library:skills",
             "library:leadership"
           ]
  end

  test "display_order/3 collapses duplicate skill-framework library tabs, preferring active" do
    tables = [
      %{name: "library:risk analyst", row_count: 67},
      %{name: "library:Risk Analyst Skill Framework", row_count: 64}
    ]

    assert Tabs.display_order(
             ["library:risk analyst", "library:Risk Analyst Skill Framework"],
             tables,
             "library:Risk Analyst Skill Framework"
           ) == ["library:Risk Analyst Skill Framework"]
  end

  test "display_order/2 keeps main when it has rows or is the only table" do
    assert Tabs.display_order(["main"], [%{name: "main", row_count: 0}]) == ["main"]

    assert Tabs.display_order(
             ["main", "library:skills"],
             [
               %{"name" => "main", "row_count" => 2},
               %{"name" => "library:skills", "row_count" => 3}
             ]
           ) == ["main", "library:skills"]
  end

  test "row_count/2 supports atom and string shaped table summaries" do
    tables = [%{name: "main", row_count: 1}, %{"name" => "other", "row_count" => 2}]

    assert Tabs.row_count(tables, "main") == 1
    assert Tabs.row_count(tables, "other") == 2
    assert Tabs.row_count(tables, "missing") == 0
  end

  test "closable?/1 keeps plumbing tabs protected" do
    refute Tabs.closable?("meta")
    refute Tabs.closable?("main")
    assert Tabs.closable?("library:skills")
  end
end
