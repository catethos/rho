defmodule RhoFrameworks.Flows.CreateFramework do
  @moduledoc """
  Flow for creating a skill framework.

  After intake the flow forks on `:choose_starting_point` (Phase 10a),
  which asks the user (or the BAML router under `routing: :auto`) which
  starting point to take:

    * **From a similar role** (`from_template_intent`) — load similar
      roles from the org's library, let the user pick one, then
      `pick_template (manual confirm) → save`. If no candidates exist
      (or the user picks none), the flow bounces back to
      `:choose_starting_point` so the user can switch to scratch.
    * **Start from scratch** (`scratch`) — `research → generate → review
      → confirm → proficiency → save`. The full LLM-driven path. Two
      guards route here: `:scratch_intent` honors the explicit form
      choice (`starting_point == "scratch"`) regardless of intake fields,
      and the implicit `:scratch` guard catches the no-signal fallback
      (blank domain + target_roles) for the chat-router path.

  `:intake` always advances to `:choose_starting_point` (no inline
  guard); the `:scratch_intent` and `:scratch` guards live on
  `:choose_starting_point`'s outgoing edges. The fork is `routing: :auto`
  so the `Hybrid` policy can let the BAML router pick from chat, while
  the wizard's `Deterministic` policy walks first-satisfied-guard.

  Each work-bearing step references a `RhoFrameworks.UseCase` module.
  Inputs are built by `build_input/3` from the runner's `intake` map and
  prior-node `summaries`. Anything table-shaped is read directly from
  the Workbench inside the UseCases.
  """

  @behaviour RhoFrameworks.Flow

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.Flows.FinalizeSkeleton
  alias RhoFrameworks.Scope

  alias RhoFrameworks.UseCases.{
    DiffFrameworks,
    GenerateFrameworkSkeletons,
    IdentifyFrameworkGaps,
    ListExistingLibraries,
    LoadExistingFramework,
    LoadSimilarRoles,
    MergeFrameworks,
    PickTemplate,
    ResearchDomain,
    ResolveConflicts
  }

  @impl true
  def id, do: "create-framework"

  @impl true
  def label, do: "Create Skill Framework"

  @impl true
  def steps do
    [
      %{
        id: :intake,
        label: "Define Framework",
        type: :form,
        next: :choose_starting_point,
        routing: :fixed,
        config: %{
          fields: [
            %{name: :name, label: "Framework Name", type: :text, required: true},
            %{name: :description, label: "Description", type: :textarea, required: true},
            %{
              name: :domain,
              label: "Domain",
              type: :text,
              placeholder: "e.g. Software Engineering"
            },
            %{
              name: :target_roles,
              label: "Target Roles",
              type: :tags,
              placeholder: "e.g. Backend Engineer, Tech Lead"
            },
            %{
              name: :skill_count,
              label: "Skill Count",
              type: :range,
              min: 8,
              max: 20,
              default: 12
            },
            %{
              name: :levels,
              label: "Proficiency Levels",
              type: :select,
              default: "5",
              options: [{"3 levels", "3"}, {"4 levels", "4"}, {"5 levels", "5"}]
            }
          ]
        }
      },
      %{
        id: :choose_starting_point,
        label: "Pick a Starting Point",
        type: :form,
        next: [
          %{
            to: :pick_existing_library,
            guard: :extend_existing_intent,
            label: "Extend an existing framework"
          },
          %{
            to: :pick_two_libraries,
            guard: :merge_intent,
            label: "Merge two existing frameworks"
          },
          %{
            to: :similar_roles,
            guard: :from_template_intent,
            label: "Look for similar existing roles to use as a template"
          },
          %{
            to: :research,
            guard: :scratch_intent,
            label: "Start from scratch — research the domain"
          },
          %{
            to: :research,
            guard: :scratch,
            label: "Research the domain (no seed roles supplied)"
          },
          %{
            to: :similar_roles,
            guard: nil,
            label: "Look for similar existing roles"
          }
        ],
        routing: :auto,
        config: %{
          fields: [
            %{
              name: :starting_point,
              label: "How would you like to start?",
              type: :select,
              required: true,
              default: "from_template",
              options: [
                {"From a similar role", "from_template"},
                {"Start from scratch", "scratch"},
                {"Extend an existing framework", "extend_existing"},
                {"Merge two existing frameworks", "merge"}
              ]
            }
          ]
        }
      },
      %{
        id: :research,
        label: "Research the Domain",
        type: :action,
        use_case: ResearchDomain,
        next: :generate,
        routing: :agent_loop,
        config: %{
          findings_table: ResearchDomain.table_name()
        }
      },
      %{
        id: :similar_roles,
        label: "Similar Roles",
        type: :select,
        use_case: LoadSimilarRoles,
        next: [
          %{
            to: :pick_template,
            guard: :good_matches,
            label: "Use a similar role as a template"
          },
          %{
            to: :choose_starting_point,
            guard: :no_similar_roles,
            label: "No matches — go back and pick a different starting point"
          }
        ],
        routing: :auto,
        config: %{
          display_fields: %{title: :name, subtitle: :role_family, detail: :skill_count},
          skippable: true
        }
      },
      %{
        id: :pick_template,
        label: "Use as Template",
        type: :action,
        use_case: PickTemplate,
        next: :save,
        routing: :fixed,
        config: %{
          manual: true,
          message:
            "Use the selected role(s) as a template? Their skills will be copied into your new framework."
        }
      },
      %{
        id: :pick_existing_library,
        label: "Pick an Existing Framework",
        type: :select,
        use_case: ListExistingLibraries,
        next: [
          %{
            to: :load_existing_library,
            guard: :existing_library_picked,
            label: "Load the picked framework"
          },
          %{
            to: :choose_starting_point,
            guard: :no_existing_libraries,
            label: "No frameworks picked — go back and choose a different starting point"
          }
        ],
        routing: :auto,
        config: %{
          display_fields: %{title: :name, subtitle: :skill_count, detail: :updated_at},
          skippable: true
        }
      },
      %{
        id: :load_existing_library,
        label: "Load Framework",
        type: :action,
        use_case: LoadExistingFramework,
        next: :identify_gaps,
        routing: :fixed,
        config: %{}
      },
      %{
        id: :identify_gaps,
        label: "Identify Gaps",
        type: :action,
        use_case: IdentifyFrameworkGaps,
        next: :generate,
        routing: :fixed,
        config: %{}
      },
      %{
        id: :pick_two_libraries,
        label: "Pick Two Frameworks",
        type: :select,
        use_case: ListExistingLibraries,
        next: [
          %{
            to: :diff_frameworks,
            guard: :two_libraries_picked,
            label: "Diff the picked frameworks"
          },
          %{
            to: :choose_starting_point,
            guard: :fewer_than_two_libraries,
            label: "Not enough frameworks — go back and choose a different starting point"
          }
        ],
        routing: :auto,
        config: %{
          display_fields: %{title: :name, subtitle: :skill_count, detail: :updated_at},
          skippable: false,
          min_select: 2,
          max_select: 2
        }
      },
      %{
        id: :diff_frameworks,
        label: "Compare Frameworks",
        type: :action,
        use_case: DiffFrameworks,
        next: :resolve_conflicts,
        routing: :fixed,
        config: %{}
      },
      %{
        id: :resolve_conflicts,
        label: "Resolve Conflicts",
        type: :table_review,
        use_case: ResolveConflicts,
        next: :merge_frameworks,
        routing: :fixed,
        config: %{conflict_mode: true}
      },
      %{
        id: :merge_frameworks,
        label: "Merge Frameworks",
        type: :action,
        use_case: MergeFrameworks,
        next: :save,
        routing: :fixed,
        config: %{}
      },
      %{
        id: :generate,
        label: "Generate Skills",
        type: :action,
        use_case: GenerateFrameworkSkeletons,
        next: :review,
        routing: :fixed,
        config: %{}
      }
    ] ++ FinalizeSkeleton.steps()
  end

  # ──────────────────────────────────────────────────────────────────────
  # Per-node input building
  # ──────────────────────────────────────────────────────────────────────

  @impl true
  def build_input(id, state, %Scope{} = scope)
      when id in [:review, :confirm, :proficiency, :save] do
    FinalizeSkeleton.build_input(id, state, scope)
  end

  def build_input(:similar_roles, %{intake: intake}, %Scope{}) do
    %{
      name: get(intake, :name),
      description: get(intake, :description),
      domain: get(intake, :domain),
      target_roles: get(intake, :target_roles)
    }
  end

  def build_input(:research, %{intake: intake}, %Scope{}) do
    %{
      name: get(intake, :name) || "",
      description: get(intake, :description) || "",
      domain: get(intake, :domain) || "",
      target_roles: get(intake, :target_roles) || ""
    }
  end

  def build_input(:generate, %{intake: intake, summaries: summaries}, %Scope{} = scope) do
    similar = Map.get(summaries, :similar_roles, %{})
    selected = Map.get(similar, :selected, [])
    load_existing = Map.get(summaries, :load_existing_library, %{})
    gaps_summary = Map.get(summaries, :identify_gaps, %{})

    base = %{
      name: get(intake, :name) || "",
      description: get(intake, :description) || "",
      domain: get(intake, :domain) || "",
      target_roles: get(intake, :target_roles) || "",
      skill_count: get(intake, :skill_count) || "12",
      similar_role_skills: format_seed_skills(selected),
      research: load_pinned_research(scope)
    }

    if extend_existing_active?(load_existing, gaps_summary) do
      Map.merge(base, %{
        scope: :gaps_only,
        table_name: Map.get(load_existing, :table_name),
        seed_skills: read_existing_skill_rows(scope, load_existing),
        gaps: Map.get(gaps_summary, :gaps, [])
      })
    else
      base
    end
  end

  def build_input(:pick_existing_library, _state, %Scope{}), do: %{}

  def build_input(:pick_two_libraries, _state, %Scope{}), do: %{}

  def build_input(:diff_frameworks, %{summaries: summaries}, %Scope{}) do
    pick = Map.get(summaries, :pick_two_libraries, %{})
    selected = Map.get(pick, :selected, [])

    {a, b} = first_two_ids(selected)
    %{library_id_a: a, library_id_b: b}
  end

  def build_input(:merge_frameworks, %{intake: intake, summaries: summaries}, %Scope{}) do
    pick = Map.get(summaries, :pick_two_libraries, %{})
    selected = Map.get(pick, :selected, [])

    {a, b} = first_two_ids(selected)
    %{library_id_a: a, library_id_b: b, new_name: get(intake, :name)}
  end

  def build_input(:load_existing_library, %{summaries: summaries}, %Scope{}) do
    pick = Map.get(summaries, :pick_existing_library, %{})
    [first | _] = Map.get(pick, :selected, []) ++ [%{}]
    %{library_id: Map.get(first, :id) || Map.get(first, "id")}
  end

  def build_input(:identify_gaps, %{intake: intake, summaries: summaries}, %Scope{}) do
    load_existing = Map.get(summaries, :load_existing_library, %{})

    %{
      library_id: Map.get(load_existing, :library_id),
      table_name: Map.get(load_existing, :table_name),
      intake: %{
        name: get(intake, :name),
        description: get(intake, :description),
        domain: get(intake, :domain),
        target_roles: get(intake, :target_roles)
      }
    }
  end

  def build_input(:pick_template, %{intake: intake, summaries: summaries}, %Scope{}) do
    similar = Map.get(summaries, :similar_roles, %{})
    selected = Map.get(similar, :selected, [])

    template_role_ids =
      selected
      |> Enum.map(fn role -> Map.get(role, :id) || Map.get(role, "id") end)
      |> Enum.reject(&is_nil/1)

    %{
      intake: %{
        name: get(intake, :name),
        description: get(intake, :description)
      },
      template_role_ids: template_role_ids
    }
  end

  def build_input(_, _state, _scope), do: %{}

  # ──────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────

  defp get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp format_seed_skills([]), do: nil
  defp format_seed_skills(nil), do: nil

  defp format_seed_skills(roles) when is_list(roles) do
    roles
    |> Enum.map_join("\n", fn role ->
      name = Map.get(role, :name) || Map.get(role, "name") || "Unknown"
      family = Map.get(role, :role_family) || Map.get(role, "role_family") || ""
      count = Map.get(role, :skill_count) || Map.get(role, "skill_count") || 0
      "- #{name} (#{family}, #{count} skills)"
    end)
  end

  defp load_pinned_research(%Scope{session_id: nil}), do: nil

  defp load_pinned_research(%Scope{session_id: session_id}) do
    case DataTable.get_rows(session_id, table: ResearchDomain.table_name()) do
      rows when is_list(rows) ->
        rows
        |> Enum.filter(&pinned?/1)
        |> Enum.map(&format_research_row/1)
        |> case do
          [] -> nil
          formatted -> Enum.join(formatted, "\n")
        end

      _ ->
        nil
    end
  end

  defp pinned?(row) do
    case Map.get(row, :pinned) || Map.get(row, "pinned") do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp format_research_row(row) do
    fact = Map.get(row, :fact) || Map.get(row, "fact") || ""
    source = Map.get(row, :source) || Map.get(row, "source") || ""
    tag = Map.get(row, :tag) || Map.get(row, "tag")
    tag_part = if tag in [nil, ""], do: "", else: " [#{tag}]"
    "- #{fact}#{tag_part} (source: #{source})"
  end

  defp extend_existing_active?(load_existing, gaps_summary) do
    is_binary(Map.get(load_existing, :table_name)) and Map.has_key?(gaps_summary, :gaps)
  end

  defp read_existing_skill_rows(%Scope{session_id: nil}, _summary), do: []

  defp read_existing_skill_rows(%Scope{session_id: sid}, %{table_name: table})
       when is_binary(sid) and is_binary(table) do
    case DataTable.get_rows(sid, table: table) do
      rows when is_list(rows) ->
        Enum.map(rows, fn row ->
          %{
            skill_name: get(row, :skill_name),
            category: get(row, :category),
            cluster: get(row, :cluster)
          }
        end)

      _ ->
        []
    end
  end

  defp read_existing_skill_rows(_, _), do: []

  defp first_two_ids(selected) when is_list(selected) do
    ids =
      selected
      |> Enum.map(fn item -> Map.get(item, :id) || Map.get(item, "id") end)
      |> Enum.reject(&is_nil/1)

    case ids do
      [a, b | _] -> {a, b}
      [a] -> {a, nil}
      [] -> {nil, nil}
    end
  end

  defp first_two_ids(_), do: {nil, nil}
end
