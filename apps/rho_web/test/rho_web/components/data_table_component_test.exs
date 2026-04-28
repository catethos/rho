defmodule RhoWeb.DataTableComponentTest do
  @moduledoc """
  Render tests for the pure-renderer `DataTableComponent`.

  These exercise the snapshot-cache interface: ordered row list,
  table_order + active_table tab strip, error banner, and the
  schema-driven column/grouping rendering.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RhoWeb.DataTableComponent
  alias RhoWeb.DataTable.Schemas

  describe "empty state" do
    test "renders empty message when rows is []" do
      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: [],
          schema: Schemas.skill_library(),
          tables: [],
          table_order: [],
          active_table: "main",
          mode_label: nil,
          error: nil,
          version: nil,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: ""
        )

      assert html =~ "No data"
    end
  end

  describe "error banner" do
    test "renders recovery message when error is :not_running" do
      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: [],
          schema: Schemas.generic(),
          tables: [],
          table_order: [],
          active_table: "main",
          mode_label: nil,
          error: :not_running,
          version: nil,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: ""
        )

      assert html =~ "Data table unavailable"
      assert html =~ "not running"
    end
  end

  describe "tab strip" do
    test "renders tab strip with multiple named tables" do
      tables = [
        %{name: "main", row_count: 3, version: 1, schema: nil},
        %{name: "library", row_count: 5, version: 2, schema: nil}
      ]

      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: [],
          schema: Schemas.generic(),
          tables: tables,
          table_order: ["main", "library"],
          active_table: "library",
          mode_label: nil,
          error: nil,
          version: 2,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: ""
        )

      assert html =~ "dt-tab-strip"
      assert html =~ "main"
      assert html =~ "library"
      assert html =~ "dt-tab-active"
    end

    test "hides tab strip when only one table" do
      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: [],
          schema: Schemas.generic(),
          tables: [%{name: "main", row_count: 0, version: 1, schema: nil}],
          table_order: ["main"],
          active_table: "main",
          mode_label: nil,
          error: nil,
          version: 1,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: ""
        )

      refute html =~ "dt-tab-strip"
    end
  end

  describe "rows rendering" do
    test "renders skill library rows with grouping" do
      rows = [
        %{
          id: "r1",
          category: "Software",
          cluster: "Languages",
          skill_name: "Elixir",
          skill_description: "Functional language",
          proficiency_levels: []
        },
        %{
          id: "r2",
          category: "Software",
          cluster: "Languages",
          skill_name: "Rust",
          skill_description: "Systems language",
          proficiency_levels: []
        }
      ]

      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: rows,
          schema: Schemas.skill_library(),
          tables: [],
          table_order: [],
          active_table: "library",
          mode_label: "Skill Library",
          error: nil,
          version: 1,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: ""
        )

      assert html =~ "Elixir"
      assert html =~ "Rust"
      assert html =~ "Software"
      assert html =~ "Languages"
      assert html =~ "Skill Framework Editor"
      assert html =~ "2 rows"
    end

    test "renders mode label when present" do
      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: [],
          schema: Schemas.role_profile(),
          tables: [],
          table_order: [],
          active_table: "role_profile",
          mode_label: "Role Profile — Test",
          error: nil,
          version: 1,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: ""
        )

      assert html =~ "Role Profile Editor"
    end
  end

  describe "Suggest button gating" do
    test "renders Suggest button on a library view" do
      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: [],
          schema: Schemas.skill_library(),
          tables: [],
          table_order: [],
          active_table: "library:Engineering",
          view_key: :skill_library,
          mode_label: nil,
          error: nil,
          version: 1,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: ""
        )

      assert html =~ "dt-suggest-btn"
      assert html =~ "Suggest"
    end

    test "expand_groups hint expands the matching category and cluster" do
      rows = [
        %{
          id: "r1",
          category: "Software",
          cluster: "Languages",
          skill_name: "Elixir",
          skill_description: "FP",
          proficiency_levels: []
        },
        %{
          id: "r2",
          category: "Process",
          cluster: "Agile",
          skill_name: "Scrum",
          skill_description: "Iterative",
          proficiency_levels: []
        }
      ]

      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: rows,
          schema: Schemas.skill_library(),
          tables: [],
          table_order: [],
          active_table: "library:Eng",
          view_key: :skill_library,
          mode_label: nil,
          error: nil,
          version: 1,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: "",
          expand_groups: [{"Software", "Languages"}]
        )

      # Software / Languages should NOT carry the dt-collapsed marker;
      # Process / Agile should remain collapsed.
      assert html =~ "Software"
      assert html =~ "Process"

      software_section =
        html
        |> String.split(~r/dt-group-l1/)
        |> Enum.find(fn section -> section =~ "Software" end)

      process_section =
        html
        |> String.split(~r/dt-group-l1/)
        |> Enum.find(fn section -> section =~ "Process" end)

      refute software_section =~ "dt-collapsed"
      assert process_section =~ "dt-collapsed"
    end

    test "hides Suggest button on a role_profile view" do
      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: [],
          schema: Schemas.role_profile(),
          tables: [],
          table_order: [],
          active_table: "role_profile",
          view_key: :role_profile,
          mode_label: nil,
          error: nil,
          version: 1,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: ""
        )

      refute html =~ "dt-suggest-btn"
    end
  end
end
