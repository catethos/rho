defmodule Rho.Stdlib.DataTable.WorkbenchContextTest do
  use ExUnit.Case, async: true

  alias Rho.Stdlib.DataTable.Schema
  alias Rho.Stdlib.DataTable.Schema.Column
  alias Rho.Stdlib.DataTable.WorkbenchContext

  defp library_schema do
    %Schema{
      name: "library",
      mode: :strict,
      columns: [
        %Column{name: :category, type: :string},
        %Column{name: :cluster, type: :string},
        %Column{name: :skill_name, type: :string},
        %Column{name: :skill_description, type: :string}
      ],
      children_key: :proficiency_levels,
      child_columns: [
        %Column{name: :level, type: :integer},
        %Column{name: :level_name, type: :string}
      ],
      child_key_fields: [:level],
      key_fields: [:skill_name]
    }
  end

  defp role_schema do
    %Schema{
      name: "role_profile",
      mode: :strict,
      columns: [
        %Column{name: :skill_name, type: :string},
        %Column{name: :required_level, type: :integer},
        %Column{name: :required, type: :boolean},
        %Column{name: :verification, type: :string}
      ],
      key_fields: [:skill_name]
    }
  end

  defp candidates_schema do
    %Schema{
      name: "role_candidates",
      mode: :strict,
      columns: [
        %Column{name: :query, type: :string},
        %Column{name: :role_id, type: :string},
        %Column{name: :role_name, type: :string},
        %Column{name: :rank, type: :integer}
      ],
      key_fields: [:query, :role_id]
    }
  end

  defp preview_schema(name) do
    %Schema{
      name: name,
      mode: :strict,
      columns: [
        %Column{name: :skill_a_name, type: :string},
        %Column{name: :skill_b_name, type: :string},
        %Column{name: :resolution, type: :string},
        %Column{name: :cluster, type: :string}
      ],
      key_fields: [:skill_a_name, :skill_b_name]
    }
  end

  defp analysis_schema do
    %Schema{
      name: "gap_analysis",
      mode: :strict,
      columns: [
        %Column{name: :skill_name, type: :string},
        %Column{name: :recommendation, type: :string},
        %Column{name: :severity, type: :string},
        %Column{name: :status, type: :string}
      ],
      key_fields: [:skill_name, :recommendation]
    }
  end

  test "infers skill library title and metrics from table name and rows" do
    rows = [
      %{
        id: "r1",
        category: "Business",
        cluster: "Growth",
        skill_name: "Fundraising",
        proficiency_levels: []
      },
      %{
        id: "r2",
        category: "Business",
        cluster: "Strategy",
        skill_name: "Market Positioning",
        proficiency_levels: [%{level: 1}, %{level: 2}]
      }
    ]

    ctx =
      WorkbenchContext.build(%{
        tables: [%{name: "library:CEO", schema: library_schema(), row_count: 2, version: 1}],
        table_order: ["library:CEO"],
        active_table: "library:CEO",
        active_snapshot: %{rows: rows},
        selections: %{"library:CEO" => MapSet.new(["r1"])}
      })

    artifact = ctx.active_artifact
    assert artifact.kind == :skill_library
    assert artifact.title == "CEO Skill Framework"
    assert artifact.metrics.skills == 2
    assert artifact.metrics.categories == 1
    assert artifact.metrics.proficiency_levels == 2
    assert artifact.metrics.missing_levels == 1
    assert :needs_levels in artifact.state

    assert artifact.selected_preview == [
             %{id: "r1", label: "Fundraising", detail: "Business, Growth, 0 levels"}
           ]
  end

  test "skill library titles do not repeat the Skill Framework suffix" do
    ctx =
      WorkbenchContext.build(%{
        tables: [
          %{
            name: "library:Risk Analyst Skill Framework",
            schema: library_schema(),
            row_count: 2,
            version: 1
          }
        ],
        table_order: ["library:Risk Analyst Skill Framework"],
        active_table: "library:Risk Analyst Skill Framework"
      })

    assert ctx.active_artifact.title == "Risk Analyst Skill Framework"
  end

  test "active artifact row count prefers fresh snapshot rows over stale table summary" do
    rows = [
      %{id: "r1", category: "Business", cluster: "Growth", skill_name: "Fundraising"},
      %{id: "r2", category: "Business", cluster: "Strategy", skill_name: "Market Positioning"}
    ]

    ctx =
      WorkbenchContext.build(%{
        tables: [%{name: "library:CEO", schema: library_schema(), row_count: 1, version: 1}],
        table_order: ["library:CEO"],
        active_table: "library:CEO",
        active_snapshot: %{rows: rows, row_count: 2}
      })

    artifact = ctx.active_artifact
    assert artifact.row_count == 2
    assert artifact.metrics.skills == 2
    assert artifact.metrics.categories == 1
  end

  test "active artifact ignores metadata for a different table" do
    ctx =
      WorkbenchContext.build(%{
        tables: [
          %{name: "library:Programming", schema: library_schema(), row_count: 16, version: 1},
          %{
            name: "library:Senior Backend Engineer",
            schema: library_schema(),
            row_count: 9,
            version: 1
          }
        ],
        table_order: ["library:Programming", "library:Senior Backend Engineer"],
        active_table: "library:Programming",
        active_snapshot: %{rows: [], row_count: 16},
        metadata: %{
          output_table: "library:Senior Backend Engineer",
          title: "Senior Backend Engineer Skill Framework",
          library_name: "Senior Backend Engineer"
        }
      })

    assert ctx.active_artifact.title == "Programming Skill Framework"
    assert ctx.active_artifact.row_count == 16
  end

  test "active artifact uses matching table metadata" do
    ctx =
      WorkbenchContext.build(%{
        tables: [%{name: "library:Programming", schema: library_schema(), row_count: 16}],
        active_table: "library:Programming",
        active_snapshot: %{rows: [], row_count: 16},
        metadata: %{
          output_table: "library:Programming",
          title: "Programming Skill Framework v2"
        }
      })

    assert ctx.active_artifact.title == "Programming Skill Framework v2"
  end

  test "distinguishes role profiles from skill libraries" do
    rows = [
      %{
        id: "r1",
        skill_name: "Budgeting",
        required: true,
        required_level: 3,
        verification: "accepted"
      },
      %{id: "r2", skill_name: "Coaching", required: false, required_level: nil, verification: ""}
    ]

    ctx =
      WorkbenchContext.build(%{
        tables: [%{name: "role_profile", schema: role_schema(), row_count: 2, version: 1}],
        active_table: "role_profile",
        active_snapshot: %{rows: rows},
        metadata: %{role_name: "CEO"}
      })

    assert ctx.active_artifact.kind == :role_profile
    assert ctx.active_artifact.title == "CEO Role Requirements"
    assert ctx.active_artifact.metrics.required_skills == 2
    assert ctx.active_artifact.metrics.required == 1
    assert ctx.active_artifact.metrics.optional == 1
    assert ctx.active_artifact.metrics.missing_required_levels == 1
    assert ctx.active_artifact.metrics.unverified == 1
  end

  test "role profile titles do not repeat Role" do
    ctx =
      WorkbenchContext.build(%{
        tables: [%{name: "role_profile", schema: role_schema(), row_count: 2, version: 1}],
        active_table: "role_profile",
        metadata: %{role_name: "Programming Role"}
      })

    assert ctx.active_artifact.title == "Programming Role Requirements"
  end

  test "role candidates expose picker metrics and selection action" do
    rows = [
      %{id: "r1", query: "Risk Analyst", role_id: "a", role_name: "Risk Manager", rank: 1},
      %{id: "r2", query: "Risk Analyst", role_id: "b", role_name: "Compliance Lead", rank: 2}
    ]

    ctx =
      WorkbenchContext.build(%{
        tables: [
          %{name: "role_candidates", schema: candidates_schema(), row_count: 2, version: 1}
        ],
        active_table: "role_candidates",
        active_snapshot: %{rows: rows},
        selections: %{"role_candidates" => ["r1"]}
      })

    assert ctx.active_artifact.kind == :role_candidates
    assert ctx.active_artifact.metrics.candidates == 2
    assert ctx.active_artifact.metrics.queries == 1
    assert ctx.active_artifact.metrics.selected == 1
    assert :seed_framework_from_selected in ctx.active_artifact.actions
  end

  test "combine and dedup previews count unresolved rows" do
    for {table, schema_name, kind} <- [
          {"combine_preview", "combine_preview", :combine_preview},
          {"dedup_preview", "dedup_preview", :dedup_preview}
        ] do
      ctx =
        WorkbenchContext.build(%{
          tables: [%{name: table, schema: preview_schema(schema_name), row_count: 2, version: 1}],
          active_table: table,
          active_snapshot: %{
            rows: [
              %{id: "r1", skill_a_name: "A", skill_b_name: "B", resolution: "unresolved"},
              %{id: "r2", skill_a_name: "C", skill_b_name: "D", resolution: "keep_both"}
            ]
          }
        })

      assert ctx.active_artifact.kind == kind
      assert ctx.active_artifact.metrics.unresolved == 1
      assert ctx.active_artifact.metrics.resolved == 1
      assert :needs_resolution in ctx.active_artifact.state
    end
  end

  test "preview metadata can supply workflow counts without full rows" do
    ctx =
      WorkbenchContext.build(%{
        tables: [
          %{
            name: "combine_preview",
            schema: preview_schema("combine_preview"),
            row_count: 4,
            version: 1
          }
        ],
        active_table: "combine_preview",
        active_snapshot: %{rows: []},
        metadata: %{
          workflow: :combine_libraries,
          artifact_kind: :combine_preview,
          clean_count: 18,
          conflict_count: 4,
          unresolved_count: 3,
          source_library_names: ["HR Assistant", "People Ops"]
        }
      })

    assert ctx.workflow.id == :combine_libraries
    assert ctx.active_artifact.metrics.pairs == 4
    assert ctx.active_artifact.metrics.clean == 18
    assert ctx.active_artifact.metrics.unresolved == 3
    assert ctx.active_artifact.metrics.resolved == 1
  end

  test "analysis results become gap review artifacts" do
    ctx =
      WorkbenchContext.build(%{
        tables: [%{name: "gap_analysis", schema: analysis_schema(), row_count: 2, version: 1}],
        active_table: "gap_analysis",
        active_snapshot: %{
          rows: [
            %{
              id: "g1",
              skill_name: "AI Governance",
              recommendation: "Add required governance skill",
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
        },
        selections: %{"gap_analysis" => ["g1"]}
      })

    assert ctx.active_artifact.kind == :analysis_result
    assert ctx.active_artifact.title == "Gap Review"
    assert ctx.active_artifact.metrics.recommendations == 2
    assert ctx.active_artifact.metrics.high_priority == 1
    assert ctx.active_artifact.metrics.unresolved == 1
    assert :needs_review in ctx.active_artifact.state
    assert :review_findings in ctx.active_artifact.actions

    assert ctx.active_artifact.selected_preview == [
             %{
               id: "g1",
               label: "Add required governance skill",
               detail: "high, open"
             }
           ]
  end

  test "falls back to a generic artifact for unknown tables" do
    ctx =
      WorkbenchContext.build(%{
        tables: [
          %{name: "research_notes", schema: Schema.dynamic("research_notes"), row_count: 3}
        ],
        active_table: "research_notes",
        active_snapshot: %{rows: []}
      })

    assert ctx.active_artifact.kind == :generic_table
    assert ctx.active_artifact.title == "Research Notes"
    assert ctx.active_artifact.metrics.rows == 3
  end

  test "treats default main as workbench plumbing until it has scratch rows" do
    empty_ctx =
      WorkbenchContext.build(%{
        tables: [%{name: "main", schema: Schema.dynamic("main"), row_count: 0}],
        table_order: ["main"],
        active_table: "main",
        active_snapshot: %{rows: []}
      })

    assert empty_ctx.active_artifact.kind == :generic_table
    assert empty_ctx.active_artifact.title == "Artifact Workbench"
    assert empty_ctx.active_artifact.subtitle =~ "Start a workflow"

    scratch_ctx =
      WorkbenchContext.build(%{
        tables: [%{name: "main", schema: Schema.dynamic("main"), row_count: 1}],
        table_order: ["main"],
        active_table: "main",
        active_snapshot: %{rows: [%{id: "r1", note: "Ad hoc"}]}
      })

    assert scratch_ctx.active_artifact.kind == :generic_table
    assert scratch_ctx.active_artifact.title == "Scratch Table"
    assert scratch_ctx.active_artifact.subtitle =~ "Ad hoc rows"
  end
end
