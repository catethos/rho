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

    case Workbench.save_framework(scope, library_id, opts) do
      {:ok, %{library: lib, saved_count: count} = result} ->
        {:ok,
         %{
           library_id: lib.id,
           library_name: lib.name,
           saved_count: count,
           draft_library_id: Map.get(result, :draft_library_id),
           research_notes_saved: Map.get(result, :research_notes_saved, 0)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Library-id resolution
  # ──────────────────────────────────────────────────────────────────────

  defp resolve_library_id(input, %Scope{} = scope) do
    case Map.get(input, :library_id) || Map.get(input, "library_id") do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        lookup_or_create_by_name(input, scope)
    end
  end

  defp lookup_or_create_by_name(input, %Scope{organization_id: org_id} = scope)
       when is_binary(org_id) do
    name = framework_name(input, scope)

    cond do
      blank?(name) ->
        nil

      true ->
        case Library.get_library_by_name(org_id, name) do
          %{id: id} ->
            id

          nil ->
            description = framework_description(input, scope)

            case Library.create_library(org_id, %{
                   name: name,
                   description: description || ""
                 }) do
              {:ok, %{id: id}} -> id
              {:error, _} -> nil
            end
        end
    end
  end

  defp lookup_or_create_by_name(_, _), do: nil

  defp framework_name(input, scope) do
    explicit = Map.get(input, :name) || Map.get(input, "name")

    cond do
      not blank?(explicit) ->
        explicit

      # If the caller passed a `library:<name>` table (the convention used by
      # load_library + import_library_from_upload), derive the name from the
      # table. Otherwise multi-library imports get collapsed under whatever's
      # in `meta`, falling back to the org's default library — that's the bug
      # the file-upload pipeline kept hitting.
      true ->
        case Map.get(input, :table_name) || Map.get(input, "table_name") do
          "library:" <> name when name != "" -> name
          _ -> meta_field(scope, :name)
        end
    end
  end

  defp framework_description(input, scope) do
    explicit = Map.get(input, :description) || Map.get(input, "description")

    if blank?(explicit), do: meta_field(scope, :description), else: explicit
  end

  defp meta_field(%Scope{session_id: sid}, key) when is_binary(sid) do
    case DataTable.get_rows(sid, table: @meta_table) do
      [row | _] -> Map.get(row, key) || Map.get(row, Atom.to_string(key))
      _ -> nil
    end
  end

  defp meta_field(_, _), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
