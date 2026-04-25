defmodule RhoFrameworks.Library.Operations do
  @moduledoc """
  Composite operations that chain library primitives.

  Each function composes `Skeletons`, `Editor`, and `Proficiency` into a
  single callable unit. Returns `{:ok, result}` or `{:error, reason}` —
  no `ToolResponse`, no `Effect` structs.
  """

  alias RhoFrameworks.Library.{Editor, Proficiency, Skeletons}
  alias RhoFrameworks.Scope

  @doc """
  Parse skill JSON, save skeletons to DataTable, and spawn proficiency writers.

  Composes: `Skeletons.parse_json` → `Skeletons.to_rows` → `Editor.append_rows`
  → `Proficiency.start_fanout`.
  """
  @spec save_and_generate(
          %{skills_json: String.t(), levels: pos_integer(), library_name: String.t()},
          Scope.t()
        ) ::
          {:ok, %{rows_added: non_neg_integer(), table_name: String.t(), workers: [map()]}}
          | {:error, term()}
  def save_and_generate(
        %{skills_json: skills_json, levels: num_levels, library_name: library_name},
        %Scope{} = rt
      ) do
    table_name = Editor.table_name(library_name)

    with {:ok, parsed} <- Skeletons.parse_json(skills_json),
         rows = Skeletons.to_rows(parsed),
         {:ok, %{count: count}} <- Editor.append_rows(%{table_name: table_name, rows: rows}, rt),
         {:ok, %{workers: workers}} <-
           Proficiency.start_fanout(
             %{rows: parsed, levels: num_levels, table_name: table_name},
             rt
           ) do
      {:ok, %{rows_added: count, table_name: table_name, workers: workers}}
    end
  end
end
