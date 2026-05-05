defmodule RhoFrameworks.Flows.EditFramework do
  @moduledoc """
  Flow for editing an existing skill framework in place.

  Pure surgical edit — load the library's skills into the session table,
  let the user tweak cell values in the `:review` step, regenerate
  proficiency, save back to the same library record. No LLM regeneration
  of the skeleton (use `:create-framework` with `starting_point=extend_existing`
  for that path).

  Step shape: `:pick_existing_library → :load_existing_library → :review`
  with a forked tail from `:review`:

    * **`:loaded_with_proficiency`** — skills already have proficiency
      levels (forked from a published standard, or the original copy was
      complete). Skip the regen prompt and go straight to `:save`.
    * **`:loaded_without_proficiency`** — fall back to the standard
      `:confirm → :proficiency → :save` tail.

  The `:review` node here overrides the one in `FinalizeSkeleton` (which
  has a single `next: :confirm`); the rest of FinalizeSkeleton's tail
  (`:confirm → :proficiency → :save`) is appended unchanged.

  ## Entry points

    * **Library landing page** — clicking the per-row "Edit" affordance
      navigates to `/orgs/:slug/flows/edit-framework?library_id=<id>`.
      The wizard pre-pre-seeds intake from the URL whitelist
      (`flow_live.ex` `@intake_param_atoms`), and the picker auto-advances
      when intake's `library_id` matches a loaded match (no extra click).
    * **Smart NL chat** — `MatchFlowIntent` recognizes "edit our X
      framework" / "update Y" → `flow_id="edit-framework"` +
      `library_hints=[X]`, which `app_live.ex` resolves to `library_id`
      via the same name-substring lookup used by extend/merge.

  When `library_id` is missing (chat hint failed to resolve, or user
  navigated without a query param), the picker renders normally and
  the user picks manually.

  ## Save semantics

  `SaveFramework` resolves the target library_id from the
  `:load_existing_library` summary, so the edit writes back to the same
  library row — no new library is created. Use `:clone-framework`
  (forthcoming) for the copy-on-save variant.
  """

  @behaviour RhoFrameworks.Flow

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.Flows.FinalizeSkeleton
  alias RhoFrameworks.MapAccess
  alias RhoFrameworks.Scope

  alias RhoFrameworks.UseCases.{
    ListExistingLibraries,
    LoadExistingFramework
  }

  # Default for the :choose_levels picker when the loaded library has no
  # proficiency at all. The user always sees and can change the picker;
  # this is just what the form starts at.
  @no_proficiency_default 5

  @impl true
  def id, do: "edit-framework"

  @impl true
  def label, do: "Edit Skill Framework"

  @impl true
  def steps do
    [
      %{
        id: :pick_existing_library,
        label: "Pick a Framework to Edit",
        type: :select,
        use_case: ListExistingLibraries,
        next: [
          %{
            to: :load_existing_library,
            guard: :existing_library_picked,
            label: "Load the picked framework"
          },
          %{
            to: :pick_existing_library,
            guard: :no_existing_libraries,
            label: "No frameworks available — stay on picker"
          }
        ],
        routing: :auto,
        config: %{
          display_fields: %{title: :name, subtitle: :skill_count, detail: :updated_at},
          skippable: false
        }
      },
      %{
        id: :load_existing_library,
        label: "Load Framework",
        type: :action,
        use_case: LoadExistingFramework,
        next: :review,
        routing: :fixed,
        config: %{}
      },
      %{
        id: :review,
        label: "Review Skills",
        type: :table_review,
        next: :confirm,
        routing: :fixed,
        config: %{}
      }
    ] ++ Enum.drop(FinalizeSkeleton.steps(), 1)
  end

  # ──────────────────────────────────────────────────────────────────────
  # Per-node input building
  # ──────────────────────────────────────────────────────────────────────

  @impl true
  def build_input(id, state, %Scope{} = scope) when id in [:review, :confirm, :proficiency] do
    FinalizeSkeleton.build_input(id, state, scope)
  end

  # Override FinalizeSkeleton's :save to pin library_id to the loaded
  # library — edit_framework writes back to the SAME row, not a new one.
  # FinalizeSkeleton's chain falls through to lookup-by-intake-name,
  # which intentionally forks for `extend_existing` but would create a
  # nameless duplicate here (intake has no `:name` for the edit flow).
  def build_input(:save, %{summaries: summaries}, %Scope{}) do
    load_existing = Map.get(summaries, :load_existing_library, %{})

    %{
      library_id: Map.get(load_existing, :library_id),
      table_name: Map.get(load_existing, :table_name)
    }
  end

  def build_input(:pick_existing_library, _state, %Scope{}), do: %{}

  def build_input(:load_existing_library, %{summaries: summaries}, %Scope{}) do
    pick = Map.get(summaries, :pick_existing_library, %{})
    [first | _] = Map.get(pick, :selected, []) ++ [%{}]
    %{library_id: Map.get(first, :id) || Map.get(first, "id")}
  end

  def build_input(_, _state, _scope), do: %{}

  # ──────────────────────────────────────────────────────────────────────
  # Smart defaults
  # ──────────────────────────────────────────────────────────────────────

  @impl true
  @doc """
  Pre-populate `intake.levels` for the `:choose_levels` step using the
  loaded library's modal proficiency-level count. Falls back to
  `@no_proficiency_default` when no skill in the workbench has any
  proficiency yet (a freshly loaded zero-proficiency library).

  The LiveView merges these intake updates only for keys not already
  present, so URL pre-fill and any prior user pick on this step take
  precedence.
  """
  def populate_intake(:choose_levels, %{summaries: summaries}, %Scope{} = scope) do
    table_name =
      get_in(summaries, [:load_existing_library, :table_name]) ||
        get_in(summaries, [:generate, :table_name])

    cond do
      is_nil(scope.session_id) or is_nil(table_name) ->
        %{}

      true ->
        case modal_level_count(scope.session_id, table_name) do
          nil -> %{levels: to_string(@no_proficiency_default)}
          n when is_integer(n) -> %{levels: to_string(n)}
        end
    end
  end

  def populate_intake(_node_id, _state, _scope), do: %{}

  defp modal_level_count(session_id, table_name) do
    case DataTable.get_rows(session_id, table: table_name) do
      rows when is_list(rows) ->
        rows
        |> Enum.map(&MapAccess.get(&1, :proficiency_levels))
        |> Enum.flat_map(fn
          list when is_list(list) and length(list) > 0 -> [length(list)]
          _ -> []
        end)
        |> case do
          [] -> nil
          counts -> mode(counts)
        end

      _ ->
        nil
    end
  end

  defp mode(counts) do
    counts
    |> Enum.frequencies()
    |> Enum.max_by(fn {_count, freq} -> freq end)
    |> elem(0)
  end
end
