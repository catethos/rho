defmodule RhoFrameworks.Flows.FinalizeSkeleton do
  @moduledoc """
  Sub-flow tail: review → confirm → proficiency → save.

  Phase 10.5 — promoted out of `RhoFrameworks.Flows.CreateFramework` once
  the scratch / extend_existing / merge forks all converged on the same
  4-step terminal sequence. This module is the "finalize a generated
  skeleton" capability — render the skill table for review, ask for a
  manual confirm, fan out proficiency-level generation per category,
  then save to the library.

  Spliced into the parent at compile time (`steps() ++
  FinalizeSkeleton.steps()`); FlowRunner walks the merged list as one
  flat node list, so `:done` and cross-module `next:` atoms (e.g.
  `:pick_template → :save`, `:merge_frameworks → :save`) resolve via
  id lookup regardless of which module declared the node.

  ## State coupling

  `build_input/3` reads parent state directly (`intake.name`,
  `intake.levels`, `summaries[:generate | :pick_template |
  :merge_frameworks | :load_existing_library].table_name`). These keys
  are stable across all three forks of CreateFramework today. If a
  future flow reuses this sub-flow with a different state shape, the
  build_input clauses move to a namespaced input map at that point —
  not now.
  """

  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.Scope

  alias RhoFrameworks.UseCases.{
    GenerateProficiency,
    SaveFramework
  }

  @doc """
  The 4-node tail. Splice into a parent flow with `++ steps()`.
  """
  @spec steps() :: [map()]
  def steps do
    [
      %{
        id: :review,
        label: "Review Skills",
        type: :table_review,
        next: :confirm,
        routing: :fixed,
        config: %{}
      },
      %{
        id: :confirm,
        label: "Confirm",
        type: :action,
        next: :choose_levels,
        routing: :fixed,
        config: %{
          manual: true,
          message: "Review complete. Generate proficiency levels for these skills?"
        }
      },
      %{
        id: :choose_levels,
        label: "Proficiency Scale",
        type: :form,
        next: :proficiency,
        routing: :fixed,
        config: %{
          fields: [
            %{
              name: :levels,
              label: "How many proficiency levels per skill?",
              type: :select,
              required: true,
              options: [{"3 levels", "3"}, {"4 levels", "4"}, {"5 levels", "5"}]
            }
          ]
        }
      },
      %{
        id: :proficiency,
        label: "Generate Proficiency Levels",
        type: :fan_out,
        use_case: GenerateProficiency,
        next: :save,
        routing: :fixed,
        config: %{}
      },
      %{
        id: :save,
        label: "Save to Library",
        type: :action,
        use_case: SaveFramework,
        next: :done,
        routing: :fixed,
        config: %{}
      }
    ]
  end

  # ──────────────────────────────────────────────────────────────────────
  # Per-node input building
  # ──────────────────────────────────────────────────────────────────────

  @spec build_input(atom(), map(), Scope.t()) :: map()
  def build_input(id, _state, %Scope{}) when id in [:review, :confirm], do: %{}

  def build_input(:proficiency, %{intake: intake, summaries: summaries}, %Scope{}) do
    table_name =
      get_in(summaries, [:generate_skills, :table_name]) ||
        get_in(summaries, [:generate, :table_name]) ||
        get_in(summaries, [:load_existing_library, :table_name]) ||
        get_in(summaries, [:pick_template, :table_name]) ||
        get_in(summaries, [:merge_frameworks, :table_name]) ||
        derive_table_name(intake)

    # Pass `intake.levels` through verbatim (nil or string). Resist the
    # urge to coerce nil → 5 here: that masked the "user never picked a
    # scale" signal that GenerateProficiency.run uses to early-exit as a
    # safety net. With :choose_levels in the shared FinalizeSkeleton tail
    # this should never be nil in practice, but the no-coerce shape keeps
    # the safety net actually safe.
    %{table_name: table_name, levels: get(intake, :levels)}
  end

  def build_input(:save, %{intake: intake, summaries: summaries}, %Scope{} = scope) do
    template_summary = Map.get(summaries, :pick_template, %{})
    generate_summary = Map.get(summaries, :generate, %{})
    generate_skills_summary = Map.get(summaries, :generate_skills, %{})
    load_existing = Map.get(summaries, :load_existing_library, %{})
    merge_summary = Map.get(summaries, :merge_frameworks, %{})

    table_name =
      Map.get(merge_summary, :table_name) ||
        Map.get(template_summary, :table_name) ||
        Map.get(generate_skills_summary, :table_name) ||
        Map.get(generate_summary, :table_name) ||
        Map.get(load_existing, :table_name) ||
        derive_table_name(intake)

    library_id =
      Map.get(merge_summary, :library_id) ||
        Map.get(template_summary, :library_id) ||
        Map.get(generate_skills_summary, :library_id) ||
        Map.get(generate_summary, :library_id) ||
        lookup_library_id(scope.organization_id, get(intake, :name))

    %{library_id: library_id, table_name: table_name}
  end

  # ──────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────

  defp get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp derive_table_name(intake) do
    name = get(intake, :name) || ""
    if name != "", do: Editor.table_name(name), else: ""
  end

  defp lookup_library_id(org_id, name) when is_binary(name) and name != "" do
    case RhoFrameworks.Library.get_library_by_name(org_id, name) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp lookup_library_id(_org_id, _name), do: nil
end
