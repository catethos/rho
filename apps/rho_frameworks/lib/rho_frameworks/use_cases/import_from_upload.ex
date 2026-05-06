defmodule RhoFrameworks.UseCases.ImportFromUpload do
  @moduledoc """
  Layer 3 — turns an `Uploads.Observation` into rows in `library:<name>`
  via `RhoFrameworks.Workbench.replace_rows/3`.

  Supports files with multiple distinct library names in the
  `Skill Library Name` column. Returns `{:ok, %{libraries: [...], warnings: []}}`.

  Spec §5.3.
  """

  @behaviour RhoFrameworks.UseCase

  alias Rho.Stdlib.DataTable
  alias Rho.Stdlib.Uploads
  alias Rho.Stdlib.Uploads.Observer
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.Library
  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.Scope
  alias RhoFrameworks.Workbench

  @impl true
  def describe do
    %{
      id: :import_from_upload,
      label: "Import library from uploaded file",
      cost_hint: :cheap,
      doc: "Import an .xlsx/.csv upload as a new library."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    upload_id = Map.fetch!(input, :upload_id)

    with {:ok, handle} <- fetch_handle(scope.session_id, upload_id),
         {:ok, obs} <- Observer.observe(scope.session_id, upload_id),
         :ok <- check_strategy(obs, input),
         {:ok, raw_rows} <- read_all_rows(handle, obs, input) do
      # If the user explicitly supplied a library_name, ignore the column
      # and force all rows under that one name.
      groups =
        case input do
          %{library_name: name} when is_binary(name) and name != "" ->
            [{name, raw_rows}]

          _ ->
            group_by_library(handle, obs, raw_rows)
        end

      import_groups(groups, obs, handle, scope)
    end
  end

  # --- Handle fetch (Uploads.get returns :error, not {:error, _}) ---

  defp fetch_handle(session_id, upload_id) do
    case Uploads.get(session_id, upload_id) do
      {:ok, handle} -> {:ok, handle}
      :error -> {:error, {:not_found, upload_id}}
    end
  end

  # --- Strategy gate ---

  defp check_strategy(%{hints: %{sheet_strategy: :roles_per_sheet}} = obs, input) do
    if explicit_sheet_override?(input) do
      :ok
    else
      sheet_names = Enum.map(obs.sheets, & &1.name)
      {:error, {:roles_per_sheet_unsupported_v1, sheet_names}}
    end
  end

  defp check_strategy(%{hints: %{sheet_strategy: :ambiguous}} = obs, _input) do
    {:error, {:ambiguous_shape, obs.hints}}
  end

  defp check_strategy(%{hints: %{sheet_strategy: :single_library}}, _input), do: :ok

  defp check_strategy(_obs, _input), do: {:error, :unsupported_observation_kind}

  defp explicit_sheet_override?(input) do
    sheet = Map.get(input, :sheet) || Map.get(input, "sheet")
    name = Map.get(input, :library_name) || Map.get(input, "library_name")
    is_binary(sheet) and sheet != "" and is_binary(name) and name != ""
  end

  # --- Read all rows once ---

  defp read_all_rows(handle, obs, input) do
    sheet_name = pick_sheet(obs, input)

    case Observer.read_sheet(handle.session_id, handle.id, sheet_name, offset: 0, limit: 1000) do
      {:ok, %{rows: raw_rows}} -> {:ok, raw_rows}
      err -> err
    end
  end

  defp pick_sheet(obs, input) do
    explicit = Map.get(input, :sheet) || Map.get(input, "sheet")

    cond do
      is_binary(explicit) and explicit != "" ->
        explicit

      true ->
        [%{name: name} | _] = obs.sheets
        name
    end
  end

  # --- Group rows by library name column ---

  defp group_by_library(handle, obs, raw_rows) do
    case obs.hints[:library_name_column] do
      nil ->
        # No library name column — put all rows under the filename-derived name
        fallback = Path.basename(handle.filename, Path.extname(handle.filename))
        [{fallback, raw_rows}]

      col ->
        # Group by whatever value is in the library-name column; nil/"" rows
        # fall back to the filename.
        fallback = Path.basename(handle.filename, Path.extname(handle.filename))

        raw_rows
        |> Enum.group_by(fn row ->
          case Map.get(row, col) do
            nil -> fallback
            "" -> fallback
            v -> to_string(v)
          end
        end)
        |> Enum.to_list()
    end
  end

  # --- Import each group, aborting on first error ---

  defp import_groups(groups, obs, handle, scope) do
    {completed, result} =
      Enum.reduce_while(groups, {[], :ok}, fn {library_name, group_rows}, {done, _} ->
        case import_one(library_name, group_rows, obs, handle, scope) do
          {:ok, summary} ->
            {:cont, {done ++ [summary], :ok}}

          {:error, reason} ->
            {:halt, {done, {:error, {library_name, reason}}}}
        end
      end)

    case result do
      :ok ->
        # Collect warnings from the observation (shared for all groups)
        {:ok, %{libraries: completed, warnings: obs.warnings}}

      {:error, {failed_library, reason}} ->
        if completed == [] do
          {:error, reason}
        else
          {:error, {:partial_import, completed, {failed_library, reason}}}
        end
    end
  end

  defp import_one(library_name, group_rows, obs, handle, scope) do
    with :ok <- check_no_collision(scope, library_name),
         table_name <- Editor.table_name(library_name),
         :ok <- ensure_table(scope.session_id, table_name),
         {:ok, rows} <- build_rows(group_rows, obs.hints, handle, library_name),
         {:ok, _} <- Workbench.replace_rows(scope, rows, table: table_name) do
      {:ok,
       %{
         library_name: library_name,
         table_name: table_name,
         skills_imported: length(rows)
       }}
    end
  end

  # --- Collision check ---

  defp check_no_collision(scope, name) do
    # Use get_library_by_name/2 directly — it does pure name-based lookup
    # via Ecto query (no UUID cast). `resolve_library/3` has a fallback
    # `by_name || get_library/2` and the second arm expects a binary_id,
    # which blows up with Ecto.Query.CastError for non-UUID library names
    # like "HR Manager".
    if valid_uuid?(scope.organization_id) do
      case Library.get_library_by_name(scope.organization_id, name) do
        nil -> :ok
        _existing -> {:error, {:library_exists, name}}
      end
    else
      # Non-UUID org_ids (used in tests) can't have any DB records.
      :ok
    end
  end

  defp valid_uuid?(nil), do: false

  defp valid_uuid?(s) when is_binary(s) do
    case Ecto.UUID.cast(s) do
      {:ok, _} -> true
      :error -> false
    end
  end

  # --- Table prep ---

  defp ensure_table(sid, table_name) do
    _ = DataTable.ensure_started(sid)
    DataTable.ensure_table(sid, table_name, DataTableSchemas.library_schema())
  end

  # --- Row building (takes pre-filtered rows for one library) ---

  defp build_rows(rows_for_library, hints, handle, library_name) do
    rows =
      rows_for_library
      |> Enum.group_by(&row_skill_key(&1, hints))
      |> Enum.map(fn {_key, group} -> build_skill_row(group, hints, handle) end)
      |> Enum.reject(&is_nil/1)

    # Refuse to silently import zero rows — a 'success' message
    # claiming "Imported 'X' — 0 skills" is worse UX than a clear error.
    if rows == [] do
      {:error, {:no_data, library_name}}
    else
      {:ok, rows}
    end
  end

  defp row_skill_key(raw, hints) do
    Map.get(raw, hints.skill_name_column)
  end

  defp build_skill_row(group, hints, handle) do
    first = hd(group)

    skill_name = Map.get(first, hints.skill_name_column)
    if skill_name in [nil, ""], do: nil, else: do_build(group, hints, handle, skill_name, first)
  end

  defp do_build(group, hints, handle, skill_name, first) do
    category = pick(first, hints.category_column, "Uncategorized")
    cluster = pick(first, hints.cluster_column, category)
    description = pick(first, hints.skill_description_column, "")

    proficiency_levels =
      if hints.level_column do
        group
        |> Enum.map(fn row ->
          level_int =
            row
            |> Map.get(hints.level_column)
            |> parse_int()

          %{
            level: level_int,
            level_name: pick(row, hints.level_name_column, ""),
            level_description: pick(row, hints.level_description_column, "")
          }
        end)
        |> Enum.reject(&is_nil(&1.level))
        |> Enum.sort_by(& &1.level)
      else
        []
      end

    %{
      category: category,
      cluster: cluster,
      skill_name: skill_name,
      skill_description: description,
      proficiency_levels: proficiency_levels,
      _source: "upload",
      _reason: "imported from #{handle.filename} (#{handle.id})"
    }
  end

  defp pick(_row, nil, default), do: default

  defp pick(row, col, default) do
    case Map.get(row, col) do
      nil -> default
      "" -> default
      v -> to_string(v)
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
