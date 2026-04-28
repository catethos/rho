defmodule RhoFrameworks.UseCases.DiffFrameworks do
  @moduledoc """
  Compute the diff between two libraries on the merge branch of
  `RhoFrameworks.Flows.CreateFramework`. Wraps
  `RhoFrameworks.Workbench.diff_frameworks/3`.

  Effect: writes conflict pairs into the session's `combine_preview`
  named table for the `:resolve_conflicts` step to render. Returns
  conflict/clean counts so the wizard can decide whether to render the
  resolve step or skip straight to merge.

  Input:

      %{library_id_a: String.t(), library_id_b: String.t()}

  Returns `{:ok, %{table_name, conflict_count, clean_count, total}}`.
  """

  @behaviour RhoFrameworks.UseCase

  alias RhoFrameworks.{Scope, Workbench}

  @impl true
  def describe do
    %{
      id: :diff_frameworks,
      label: "Diff two frameworks",
      cost_hint: :instant,
      doc: "Compare two libraries and stage conflict pairs for review."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    a = get(input, :library_id_a)
    b = get(input, :library_id_b)

    cond do
      blank?(a) -> {:error, :missing_library_id_a}
      blank?(b) -> {:error, :missing_library_id_b}
      a == b -> {:error, :duplicate_library_ids}
      true -> Workbench.diff_frameworks(scope, a, b)
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
