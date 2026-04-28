defmodule RhoFrameworks.UseCases.MergeFrameworks do
  @moduledoc """
  Persist the merged library composed from two source libraries plus
  per-conflict resolutions on the merge branch of
  `RhoFrameworks.Flows.CreateFramework`. Wraps
  `RhoFrameworks.Workbench.merge_frameworks/5`.

  Resolutions are read from the session's `combine_preview` named table
  (which the `:resolve_conflicts` step has rewritten with user picks),
  not passed via input. The wizard's intake `:name` becomes the new
  library's name.

  Input:

      %{library_id_a: String.t(), library_id_b: String.t(), new_name: String.t()}

  Returns `{:ok, %{library_id, library_name, table_name, skill_count}}`.
  """

  @behaviour RhoFrameworks.UseCase

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{Scope, Workbench}

  @impl true
  def describe do
    %{
      id: :merge_frameworks,
      label: "Merge two frameworks",
      cost_hint: :instant,
      doc: "Persist a merged library from two sources with user-picked resolutions."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    a = get(input, :library_id_a)
    b = get(input, :library_id_b)
    name = get(input, :new_name)

    cond do
      blank?(a) ->
        {:error, :missing_library_id_a}

      blank?(b) ->
        {:error, :missing_library_id_b}

      blank?(name) ->
        {:error, :missing_new_name}

      true ->
        resolutions = read_resolutions(scope.session_id)
        Workbench.merge_frameworks(scope, a, b, name, resolutions)
    end
  end

  defp read_resolutions(nil), do: []

  defp read_resolutions(session_id) when is_binary(session_id) do
    case DataTable.get_rows(session_id, table: Workbench.combine_preview_table()) do
      rows when is_list(rows) -> rows
      _ -> []
    end
  end

  defp get(input, key) do
    Map.get(input, key) || Map.get(input, Atom.to_string(key))
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
