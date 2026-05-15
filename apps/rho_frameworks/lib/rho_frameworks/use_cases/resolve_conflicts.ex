defmodule RhoFrameworks.UseCases.ResolveConflicts do
  @moduledoc """
  Confirm the user has resolved every conflict in the session's
  `combine_preview` named table. The actual per-row resolution edits
  land via `Rho.Stdlib.DataTable.update_cells/3` while the user clicks
  "Use A" / "Use B" / "Keep both" in the conflict UI — this UseCase
  only validates that no row is still `unresolved` before advancing to
  `:merge_frameworks`.

  Returns `{:ok, %{resolved_count}}` on success, or
  `{:error, {:unresolved, count}}` when at least one conflict row still
  has `resolution: "unresolved"`.
  """

  @behaviour RhoFrameworks.UseCase

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{Scope, Workbench}

  @impl true
  def describe do
    %{
      id: :resolve_conflicts,
      label: "Confirm conflict resolutions",
      cost_hint: :instant,
      doc: "Verify all conflict rows have a resolution before merging."
    }
  end

  @impl true
  def run(_input, %Scope{} = scope) do
    rows =
      case DataTable.get_rows(scope.session_id, table: Workbench.combine_preview_table()) do
        rows when is_list(rows) -> rows
        _ -> []
      end

    case Enum.split_with(rows, &resolved?/1) do
      {resolved, []} ->
        {:ok, %{resolved_count: length(resolved), unresolved_count: 0}}

      {_resolved, unresolved} ->
        {:error, {:unresolved, length(unresolved)}}
    end
  end

  defp resolved?(row) do
    case Rho.MapAccess.get(row, :resolution) do
      v when v in ["merge_a", "merge_b", "keep_both"] -> true
      _ -> false
    end
  end
end
