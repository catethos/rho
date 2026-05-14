defmodule RhoFrameworks.UseCases.SaveFramework do
  @moduledoc """
  Persist the session's library table back to a library record.

  Resolution order for the target library:

    1. Explicit `:library_id` from input (existing/draft).
    2. Lookup-or-create by **framework name**, taken from the session's
       `meta` table (or, as a fallback, the `:name` field on the input).
       Phase 6 onward generates the library record on save instead of
       upfront, so the wizard's intake name flows in via meta.
    3. Org's default library (last resort — `Workbench.save_framework`).

  After resolving, delegates to `RhoFrameworks.Workbench.save_framework/3`.
  """
  @behaviour RhoFrameworks.UseCase
  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{Library, Scope, Workbench}
  @meta_table "meta"
  @impl true
  def describe do
    %{
      id: :save_framework,
      label: "Save framework to library",
      cost_hint: :instant,
      doc: "Persist the framework currently in the session's library table to the database."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    library_id = resolve_library_id(input, scope)

    opts =
      case Map.get(input, :table_name) || Map.get(input, "table_name") do
        nil -> []
        "" -> []
        table -> [table: table]
      end

    library_table = Keyword.get(opts, :table) || default_library_table(scope, library_id)
    dedup_outcome = apply_dedup_resolutions(scope, library_id, library_table)

    case Workbench.save_framework(scope, library_id, opts) do
      {:ok, %{library: lib, saved_count: count} = result} ->
        {:ok,
         %{
           library_id: lib.id,
           library_name: lib.name,
           saved_count: count,
           draft_library_id: Map.get(result, :draft_library_id),
           research_notes_saved: Map.get(result, :research_notes_saved, 0),
           dedup_applied: dedup_outcome
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_dedup_resolutions(%Scope{session_id: sid}, library_id, library_table)
       when is_binary(sid) and is_binary(library_id) do
    case DataTable.get_rows(sid, table: "dedup_preview") do
      rows when is_list(rows) and rows != [] ->
        outcome = do_apply_resolutions(sid, library_id, library_table, rows)
        DataTable.replace_all(sid, [], table: "dedup_preview")
        outcome

      _ ->
        %{merged: 0, dismissed: 0, skipped: 0, errors: []}
    end
  end

  defp apply_dedup_resolutions(_, _, _) do
    %{merged: 0, dismissed: 0, skipped: 0, errors: []}
  end

  defp do_apply_resolutions(sid, library_id, library_table, rows) do
    initial = %{merged: 0, dismissed: 0, skipped: 0, errors: []}

    Enum.reduce(rows, initial, fn row, acc ->
      a_id = field(row, :skill_a_id)
      b_id = field(row, :skill_b_id)
      a_name = field(row, :skill_a_name)
      b_name = field(row, :skill_b_name)
      resolution = field(row, :resolution)

      case {resolution, a_id, b_id} do
        {res, a, b} when is_binary(a) and is_binary(b) and res in ["merge_a", "merge_b"] ->
          {keep, absorb, absorbed_name} =
            if res == "merge_a" do
              {a, b, b_name}
            else
              {b, a, a_name}
            end

          case Library.merge_skills(absorb, keep) do
            {:ok, _} ->
              drop_absorbed_row(sid, library_table, absorbed_name)
              %{acc | merged: acc.merged + 1}

            {:error, reason} ->
              %{acc | errors: [{a, b, reason} | acc.errors]}
          end

        {"keep_both", a, b} when is_binary(a) and is_binary(b) ->
          case Library.dismiss_duplicate(library_id, a, b) do
            {:ok, _} -> %{acc | dismissed: acc.dismissed + 1}
            {:error, reason} -> %{acc | errors: [{a, b, reason} | acc.errors]}
          end

        _ ->
          %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  defp drop_absorbed_row(_sid, nil, _name) do
    :ok
  end

  defp drop_absorbed_row(_sid, _table, "") do
    :ok
  end

  defp drop_absorbed_row(_sid, _table, name) when not is_binary(name) do
    :ok
  end

  defp drop_absorbed_row(sid, table, name) do
    DataTable.delete_by_filter(sid, %{skill_name: name}, table: table)
    :ok
  end

  defp default_library_table(_, nil) do
    nil
  end

  defp default_library_table(%Scope{organization_id: org_id}, library_id)
       when is_binary(org_id) and is_binary(library_id) do
    case Library.get_library(org_id, library_id) do
      %{name: name} when is_binary(name) -> "library:" <> name
      _ -> nil
    end
  end

  defp default_library_table(_, _) do
    nil
  end

  defp field(row, key) when is_atom(key) do
    Map.get(row, key) || Map.get(row, Atom.to_string(key))
  end

  defp resolve_library_id(input, %Scope{} = scope) do
    case Map.get(input, :library_id) || Map.get(input, "library_id") do
      id when is_binary(id) and id != "" -> id
      _ -> lookup_or_create_by_name(input, scope)
    end
  end

  defp lookup_or_create_by_name(input, %Scope{organization_id: org_id} = scope)
       when is_binary(org_id) do
    name = framework_name(input, scope)

    if blank?(name) do
      nil
    else
      case Library.get_library_by_name(org_id, name) do
        %{id: id} ->
          id

        nil ->
          description = framework_description(input, scope)

          case Library.create_library(org_id, %{name: name, description: description || ""}) do
            {:ok, %{id: id}} -> id
            {:error, _} -> nil
          end
      end
    end
  end

  defp lookup_or_create_by_name(_, _) do
    nil
  end

  defp framework_name(input, scope) do
    explicit = Map.get(input, :name) || Map.get(input, "name")

    if not blank?(explicit) do
      explicit
    else
      case Map.get(input, :table_name) || Map.get(input, "table_name") do
        "library:" <> name when name != "" -> name
        _ -> meta_field(scope, :name)
      end
    end
  end

  defp framework_description(input, scope) do
    explicit = Map.get(input, :description) || Map.get(input, "description")

    if blank?(explicit) do
      meta_field(scope, :description)
    else
      explicit
    end
  end

  defp meta_field(%Scope{session_id: sid}, key) when is_binary(sid) do
    case DataTable.get_rows(sid, table: @meta_table) do
      [row | _] -> Map.get(row, key) || Map.get(row, Atom.to_string(key))
      _ -> nil
    end
  end

  defp meta_field(_, _) do
    nil
  end

  defp blank?(nil) do
    true
  end

  defp blank?("") do
    true
  end

  defp blank?(s) when is_binary(s) do
    String.trim(s) == ""
  end

  defp blank?(_) do
    false
  end
end
