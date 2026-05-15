defmodule RhoWeb.DataTableComponentTest do
  @moduledoc """
  Render tests for the pure-renderer `DataTableComponent`.

  These exercise the snapshot-cache interface: ordered row list,
  table_order + active_table tab strip, error banner, and the
  schema-driven column/grouping rendering.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rho.Stdlib.DataTable.Schema, as: StorageSchema
  alias Rho.Stdlib.DataTable.Schema.Column, as: StorageColumn
  alias Rho.Stdlib.DataTable.WorkbenchContext
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

    test "renders semantic artifact tab badges from workbench context" do
      library_schema = %StorageSchema{
        name: "library",
        columns: [
          %StorageColumn{name: :category, type: :string},
          %StorageColumn{name: :skill_name, type: :string}
        ],
        key_fields: [:skill_name]
      }

      candidates_schema = %StorageSchema{
        name: "role_candidates",
        columns: [
          %StorageColumn{name: :query, type: :string},
          %StorageColumn{name: :role_name, type: :string}
        ],
        key_fields: [:query, :role_name]
      }

      candidate_rows = [
        %{id: "r1", query: "Risk Analyst", role_name: "Risk Analyst"},
        %{id: "r2", query: "Risk Analyst", role_name: "Compliance Analyst"}
      ]

      tables = [
        %{name: "library:CEO", schema: library_schema, row_count: 2, version: 1},
        %{name: "role_candidates", schema: candidates_schema, row_count: 2, version: 1}
      ]

      workbench_context =
        WorkbenchContext.build(%{
          tables: tables,
          table_order: ["library:CEO", "role_candidates"],
          active_table: "role_candidates",
          active_snapshot: %{rows: candidate_rows},
          selections: %{"role_candidates" => MapSet.new(["r1"])}
        })

      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: candidate_rows,
          schema: Schemas.role_candidates(),
          workbench_context: workbench_context,
          tables: tables,
          table_order: ["library:CEO", "role_candidates"],
          active_table: "role_candidates",
          view_key: :role_candidates,
          mode_label: nil,
          error: nil,
          version: 1,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          selected_ids: MapSet.new(["r1"]),
          class: ""
        )

      assert html =~ "CEO Skill Framework"
      assert html =~ "2 skills"
      assert html =~ "Candidate Roles"
      assert html =~ "1 selected"
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
    test "renders active artifact title and metrics from workbench context" do
      rows = [
        %{
          id: "r1",
          category: "Business",
          cluster: "Growth",
          skill_name: "Fundraising",
          skill_description: "Raises capital",
          proficiency_levels: []
        },
        %{
          id: "r2",
          category: "Business",
          cluster: "Strategy",
          skill_name: "Market Positioning",
          skill_description: "Finds market space",
          proficiency_levels: [%{level: 1}]
        }
      ]

      storage_schema = %StorageSchema{
        name: "library",
        columns: [
          %StorageColumn{name: :category, type: :string},
          %StorageColumn{name: :cluster, type: :string},
          %StorageColumn{name: :skill_name, type: :string}
        ],
        children_key: :proficiency_levels,
        key_fields: [:skill_name]
      }

      workbench_context =
        WorkbenchContext.build(%{
          tables: [%{name: "library:CEO", schema: storage_schema, row_count: 2, version: 1}],
          table_order: ["library:CEO"],
          active_table: "library:CEO",
          active_snapshot: %{rows: rows},
          metadata: %{source_label: "CEO Job Description.pdf", linked_role_table: "role_profile"}
        })

      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: rows,
          schema: Schemas.skill_library(),
          workbench_context: workbench_context,
          tables: [%{name: "library:CEO", row_count: 2, version: 1, schema: storage_schema}],
          table_order: ["library:CEO"],
          active_table: "library:CEO",
          mode_label: "Skill Library",
          error: nil,
          version: 1,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: ""
        )

      assert html =~ "CEO Skill Framework"
      assert html =~ "Reusable skill taxonomy"
      assert html =~ "CEO Job Description.pdf"
      assert html =~ "2 skills"
      assert html =~ "1 need level"
      refute html =~ "Save draft"
      refute html =~ "Generate levels"
      assert html =~ "Linked artifacts"
      assert html =~ "role requirements"
    end

    test "renders role candidates as a picker surface" do
      rows = [
        %{
          id: "r1",
          query: "Risk Analyst",
          rank: 1,
          role_id: "role-1",
          role_name: "Risk Analyst",
          role_family: "Risk",
          seniority_label: "Senior",
          skill_count: 18
        },
        %{
          id: "r2",
          query: "Risk Analyst",
          rank: 2,
          role_id: "role-2",
          role_name: "Compliance Analyst",
          role_family: "Compliance",
          seniority_label: "Mid",
          skill_count: 14
        }
      ]

      storage_schema = %StorageSchema{
        name: "role_candidates",
        columns: [
          %StorageColumn{name: :query, type: :string},
          %StorageColumn{name: :role_name, type: :string}
        ],
        key_fields: [:query, :role_id]
      }

      workbench_context =
        WorkbenchContext.build(%{
          tables: [%{name: "role_candidates", schema: storage_schema, row_count: 2, version: 1}],
          table_order: ["role_candidates"],
          active_table: "role_candidates",
          active_snapshot: %{rows: rows},
          selections: %{"role_candidates" => MapSet.new(["r1"])}
        })

      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: rows,
          schema: Schemas.role_candidates(),
          workbench_context: workbench_context,
          tables: [%{name: "role_candidates", row_count: 2, version: 1, schema: storage_schema}],
          table_order: ["role_candidates"],
          active_table: "role_candidates",
          view_key: :role_candidates,
          mode_label: nil,
          error: nil,
          version: 1,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          selected_ids: MapSet.new(["r1"]),
          class: ""
        )

      assert html =~ "Picker"
      assert html =~ "Choose source roles"
      assert html =~ "2 candidates"
      assert html =~ "1 selected"
      assert html =~ "Seed Framework"
    end

    test "renders combine preview as a conflict decision queue" do
      rows = [
        %{id: "c1", skill_a_name: "Hiring", skill_b_name: "Talent Acquisition", resolution: ""},
        %{
          id: "c2",
          skill_a_name: "Onboarding",
          skill_b_name: "Employee Onboarding",
          resolution: "merge_a"
        }
      ]

      storage_schema = %StorageSchema{
        name: "combine_preview",
        columns: [
          %StorageColumn{name: :skill_a_name, type: :string},
          %StorageColumn{name: :skill_b_name, type: :string},
          %StorageColumn{name: :resolution, type: :string}
        ],
        key_fields: [:skill_a_name, :skill_b_name]
      }

      workbench_context =
        WorkbenchContext.build(%{
          tables: [%{name: "combine_preview", schema: storage_schema, row_count: 2, version: 1}],
          table_order: ["combine_preview"],
          active_table: "combine_preview",
          active_snapshot: %{rows: rows},
          metadata: %{ui_intent: %{surface: :conflict_review}}
        })

      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: rows,
          schema: Schemas.combine_conflicts(),
          workbench_context: workbench_context,
          tables: [%{name: "combine_preview", row_count: 2, version: 1, schema: storage_schema}],
          table_order: ["combine_preview"],
          active_table: "combine_preview",
          view_key: :combine_conflicts,
          mode_label: nil,
          error: nil,
          version: 1,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: ""
        )

      assert html =~ "Decision queue"
      assert html =~ "Resolve combine conflicts"
      assert html =~ "1 unresolved"
      assert html =~ "Needs decisions"
    end

    test "renders analysis result as a gap review surface" do
      rows = [
        %{
          id: "g1",
          skill_name: "AI Governance",
          recommendation: "Add governance skill",
          severity: "high",
          status: "open"
        },
        %{
          id: "g2",
          skill_name: "Data Literacy",
          recommendation: "Raise required level",
          severity: "medium",
          status: "accepted"
        }
      ]

      storage_schema = %StorageSchema{
        name: "gap_analysis",
        columns: [
          %StorageColumn{name: :skill_name, type: :string},
          %StorageColumn{name: :recommendation, type: :string},
          %StorageColumn{name: :severity, type: :string},
          %StorageColumn{name: :status, type: :string}
        ],
        key_fields: [:skill_name, :recommendation]
      }

      workbench_context =
        WorkbenchContext.build(%{
          tables: [%{name: "gap_analysis", schema: storage_schema, row_count: 2, version: 1}],
          table_order: ["gap_analysis"],
          active_table: "gap_analysis",
          active_snapshot: %{rows: rows},
          metadata: %{artifact_kind: :analysis_result, ui_intent: %{surface: :gap_review}}
        })

      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: rows,
          schema: Schemas.generic(),
          workbench_context: workbench_context,
          tables: [%{name: "gap_analysis", row_count: 2, version: 1, schema: storage_schema}],
          table_order: ["gap_analysis"],
          active_table: "gap_analysis",
          view_key: :generic,
          mode_label: nil,
          error: nil,
          version: 1,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: ""
        )

      assert html =~ "Gap Review"
      assert html =~ "Recommendations"
      assert html =~ "2 findings"
      assert html =~ "1 high priority"
      assert html =~ "Needs review"
      refute html =~ "Review findings"
    end

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

      # Pass `expand_groups` so the leaf group's stream is eagerly seeded —
      # without this, lazy population leaves the streamed `<tbody>` empty
      # until the user clicks to expand.
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
          class: "",
          expand_groups: [{"Software", "Languages"}]
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

    test "collapsed groups have empty streams (lazy population)" do
      rows = [
        %{
          id: "r1",
          category: "Software",
          cluster: "Languages",
          skill_name: "Elixir",
          skill_description: "Functional language",
          proficiency_levels: []
        }
      ]

      # No expand_groups hint → all groups stay collapsed → row content
      # never lands in the rendered HTML, but the streamed `<tbody>` is
      # still present (empty) so the user can expand to populate.
      html =
        render_component(DataTableComponent,
          id: "dt1",
          rows: rows,
          schema: Schemas.skill_library(),
          tables: [],
          table_order: [],
          active_table: "library",
          mode_label: nil,
          error: nil,
          version: 1,
          streaming: false,
          total_cost: 0.0,
          session_id: "s1",
          class: ""
        )

      assert html =~ ~r/<tbody[^>]+phx-update="stream"/
      refute html =~ "Elixir"
      assert html =~ "Software"
      assert html =~ "Languages"
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
