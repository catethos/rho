defmodule RhoFrameworks.UseCases.ImportFromUpload do
  @moduledoc """
  Layer 3 — turns an `Uploads.Observation` into rows in `library:<name>`
  via `RhoFrameworks.Workbench.replace_rows/3`.

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
         {:ok, library_name} <- resolve_library_name(handle, obs, input),
         :ok <- check_no_collision(scope, library_name),
         table_name <- Editor.table_name(library_name),
         :ok <- ensure_table(scope.session_id, table_name),
         {:ok, rows} <- build_rows(handle, obs, input),
         {:ok, _} <- Workbench.replace_rows(scope, rows, table: table_name) do
      {:ok,
       %{
         library_name: library_name,
         table_name: table_name,
         skills_imported: length(rows),
         roles_imported: 0,
         warnings: obs.warnings
       }}
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

  defp check_strategy(%{hints: %{sheet_strategy: :roles_per_sheet}} = obs, _input) do
    sheet_names = Enum.map(obs.sheets, & &1.name)
    {:error, {:roles_per_sheet_unsupported_v1, sheet_names}}
  end

  defp check_strategy(%{hints: %{sheet_strategy: :ambiguous}} = obs, _input) do
    {:error, {:ambiguous_shape, obs.hints}}
  end

  defp check_strategy(%{hints: %{sheet_strategy: :single_library}}, _input), do: :ok

  defp check_strategy(_obs, _input), do: {:error, :unsupported_observation_kind}

  # --- Library name ---

  defp resolve_library_name(_handle, _obs, %{library_name: name})
       when is_binary(name) and name != "" do
    {:ok, name}
  end

  defp resolve_library_name(handle, obs, _input) do
    case obs.hints[:library_name_column] do
      nil -> {:ok, Path.basename(handle.filename, Path.extname(handle.filename))}
      col -> resolve_from_column(handle, obs, col)
    end
  end

  defp resolve_from_column(handle, obs, col) do
    [%{name: sheet_name} | _] = obs.sheets
    sid = handle.session_id

    case Observer.read_sheet(sid, handle.id, sheet_name, offset: 0, limit: 1) do
      {:ok, %{rows: [row | _]}} ->
        case Map.get(row, col) do
          nil -> {:ok, Path.basename(handle.filename, Path.extname(handle.filename))}
          "" -> {:ok, Path.basename(handle.filename, Path.extname(handle.filename))}
          v -> {:ok, to_string(v)}
        end

      _ ->
        {:ok, Path.basename(handle.filename, Path.extname(handle.filename))}
    end
  end

  # --- Collision check ---

  defp check_no_collision(scope, name) do
    # Library.resolve_library/3 returns nil when not found — does NOT raise.
    # The organization_id must be a valid UUID (:binary_id); non-UUID org_ids
    # (used in tests) cannot have any DB records so we short-circuit to :ok.
    if valid_uuid?(scope.organization_id) do
      case Library.resolve_library(scope.organization_id, name, nil) do
        nil -> :ok
        _existing -> {:error, {:library_exists, name}}
      end
    else
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

  # --- Row building ---

  defp build_rows(handle, obs, _input) do
    [%{name: sheet_name} | _] = obs.sheets

    case Observer.read_sheet(handle.session_id, handle.id, sheet_name, offset: 0, limit: 1000) do
      {:ok, %{rows: raw_rows}} ->
        rows =
          raw_rows
          |> Enum.group_by(&row_skill_key(&1, obs.hints))
          |> Enum.map(fn {_key, group} -> build_skill_row(group, obs.hints, handle) end)
          |> Enum.reject(&is_nil/1)

        # Refuse to silently import zero rows — a 'success' message
        # claiming "Imported 'X' — 0 skills" is worse UX than a clear error.
        if rows == [] do
          {:error, {:no_data, sheet_name}}
        else
          {:ok, rows}
        end

      err ->
        err
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
