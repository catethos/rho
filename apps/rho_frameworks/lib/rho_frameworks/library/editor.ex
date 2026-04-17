defmodule RhoFrameworks.Library.Editor do
  @moduledoc """
  Session/table-backed library editing primitives.

  Every function takes `(params, Runtime.t())` and returns
  `{:ok, result}` or `{:error, reason}` — no `ToolResponse`, no `Effect`
  structs. Agent tools and FlowLive both call these directly.
  """

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.Library, as: LibraryCtx
  alias RhoFrameworks.Runtime

  # -------------------------------------------------------------------
  # Table naming
  # -------------------------------------------------------------------

  @doc "Canonical table name for a library: `\"library:<name>\"`."
  @spec table_name(String.t()) :: String.t()
  def table_name(lib_name) when is_binary(lib_name), do: "library:#{lib_name}"

  @doc "Returns everything needed to set up or reference a library table."
  @spec table_spec(String.t()) :: %{
          name: String.t(),
          schema: Rho.Stdlib.DataTable.Schema.t(),
          schema_key: atom(),
          mode_label: String.t()
        }
  def table_spec(lib_name) when is_binary(lib_name) do
    %{
      name: table_name(lib_name),
      schema: DataTableSchemas.library_schema(),
      schema_key: :skill_library,
      mode_label: "Skill Library — #{lib_name}"
    }
  end

  # -------------------------------------------------------------------
  # Create
  # -------------------------------------------------------------------

  @doc """
  Create a library record and ensure the DataTable is initialized.

  Returns `{:ok, %{library: library, table: table_spec}}` on success.
  """
  @spec create(%{name: String.t(), description: String.t()}, Runtime.t()) ::
          {:ok, %{library: struct(), table: map()}} | {:error, term()}
  def create(%{name: name} = params, %Runtime{} = rt) do
    description = Map.get(params, :description, "")

    case LibraryCtx.create_library(rt.organization_id, %{name: name, description: description}) do
      {:ok, lib} ->
        spec = table_spec(lib.name)

        case DataTable.ensure_table(rt.session_id, spec.name, spec.schema) do
          :ok ->
            {:ok, %{library: lib, table: spec}}

          {:error, reason} ->
            {:ok, %{library: lib, table: spec, table_error: reason}}
        end

      {:error, changeset} ->
        {:error, {:validation, changeset.errors}}
    end
  end

  # -------------------------------------------------------------------
  # Read rows
  # -------------------------------------------------------------------

  @doc "Read all rows from the named library DataTable."
  @spec read_rows(%{table_name: String.t()}, Runtime.t()) ::
          {:ok, [map()]} | {:error, term()}
  def read_rows(%{table_name: tbl}, %Runtime{} = rt) do
    case DataTable.get_rows(rt.session_id, table: tbl) do
      {:error, :not_running} ->
        {:error, {:not_running, tbl}}

      rows when is_list(rows) ->
        {:ok, rows}
    end
  end

  # -------------------------------------------------------------------
  # Save table → DB
  # -------------------------------------------------------------------

  @doc """
  Read rows from DataTable and persist to a library in the database.

  If `library_id` is nil, uses or creates the org's default library.
  Handles published libraries by auto-creating a draft.
  """
  @spec save_table(%{library_id: String.t() | nil, table_name: String.t()}, Runtime.t()) ::
          {:ok,
           %{
             library: struct(),
             saved_count: non_neg_integer(),
             draft_library_id: String.t() | nil
           }}
          | {:error, term()}
  def save_table(%{table_name: tbl} = params, %Runtime{} = rt) do
    with {:ok, lib} <- resolve_target_library(params, rt),
         {:ok, rows} <- read_rows_for_save(tbl, rt) do
      case LibraryCtx.save_to_library(rt.organization_id, lib.id, rows) do
        {:ok, %{skills: skills} = result} ->
          {:ok,
           %{
             library: lib,
             saved_count: length(skills),
             draft_library_id: Map.get(result, :draft_library_id)
           }}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, step, changeset, _} ->
          {:error, {:save_failed, step, changeset}}
      end
    end
  end

  # -------------------------------------------------------------------
  # Append rows
  # -------------------------------------------------------------------

  @doc "Append rows to an existing library DataTable."
  @spec append_rows(%{table_name: String.t(), rows: [map()]}, Runtime.t()) ::
          {:ok, %{count: non_neg_integer()}} | {:error, term()}
  def append_rows(%{table_name: tbl, rows: rows}, %Runtime{} = rt) do
    case DataTable.add_rows(rt.session_id, rows, table: tbl) do
      {:ok, inserted} ->
        {:ok, %{count: length(inserted)}}

      {:error, :not_running} ->
        {:error, {:not_running, tbl}}

      {:error, :not_found} ->
        {:error, {:not_running, tbl}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------
  # Replace rows
  # -------------------------------------------------------------------

  @doc "Replace all rows in a library DataTable."
  @spec replace_rows(%{table_name: String.t(), rows: [map()]}, Runtime.t()) ::
          {:ok, %{count: non_neg_integer()}} | {:error, term()}
  def replace_rows(%{table_name: tbl, rows: rows}, %Runtime{} = rt) do
    case DataTable.replace_all(rt.session_id, rows, table: tbl) do
      {:ok, _replaced} ->
        {:ok, %{count: length(rows)}}

      {:error, :not_running} ->
        {:error, {:not_running, tbl}}

      {:error, :not_found} ->
        {:error, {:not_running, tbl}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------
  # Apply proficiency levels
  # -------------------------------------------------------------------

  @doc """
  Match skill entries by `skill_name` and update their `proficiency_levels` field.

  Takes native Elixir maps (not JSON strings). Returns counts of updated and
  skipped skills.
  """
  @spec apply_proficiency_levels(
          %{table_name: String.t(), skill_levels: [map()]},
          Runtime.t()
        ) :: {:ok, %{updated_count: non_neg_integer(), skipped: [String.t()]}} | {:error, term()}
  def apply_proficiency_levels(%{table_name: tbl, skill_levels: skill_levels}, %Runtime{} = rt) do
    with {:ok, rows} <- read_rows(%{table_name: tbl}, rt) do
      rows_by_name =
        Map.new(rows, fn row ->
          {to_string(row[:skill_name] || row["skill_name"] || ""), row}
        end)

      {changes, matched, skipped} =
        Enum.reduce(skill_levels, {[], [], []}, fn entry, {ch_acc, m_acc, s_acc} ->
          skill_name = to_string(entry["skill_name"] || entry[:skill_name] || "")
          levels = entry["levels"] || entry[:levels] || []

          proficiency_levels =
            Enum.map(levels, fn lvl ->
              %{
                level: lvl["level"] || lvl[:level] || 1,
                level_name: lvl["level_name"] || lvl[:level_name] || "",
                level_description: lvl["level_description"] || lvl[:level_description] || ""
              }
            end)

          case Map.get(rows_by_name, skill_name) do
            nil ->
              {ch_acc, m_acc, [skill_name | s_acc]}

            row ->
              row_id = to_string(row[:id] || row["id"])

              change = %{
                "id" => row_id,
                "field" => "proficiency_levels",
                "value" => proficiency_levels
              }

              {[change | ch_acc], [skill_name | m_acc], s_acc}
          end
        end)

      if changes == [] do
        {:error, {:no_matches, Enum.reverse(skipped)}}
      else
        case DataTable.update_cells(rt.session_id, changes, table: tbl) do
          :ok ->
            {:ok, %{updated_count: length(matched), skipped: Enum.reverse(skipped)}}

          {:error, reason} ->
            {:error, {:update_failed, reason}}
        end
      end
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp resolve_target_library(%{library_id: nil}, %Runtime{} = rt) do
    {:ok, LibraryCtx.get_or_create_default_library(rt.organization_id)}
  end

  defp resolve_target_library(%{library_id: id}, %Runtime{} = rt) when is_binary(id) do
    case LibraryCtx.get_library(rt.organization_id, id) do
      nil -> {:error, :not_found}
      lib -> {:ok, lib}
    end
  end

  defp resolve_target_library(%{}, %Runtime{} = rt) do
    {:ok, LibraryCtx.get_or_create_default_library(rt.organization_id)}
  end

  defp read_rows_for_save(tbl, rt) do
    case DataTable.get_rows(rt.session_id, table: tbl) do
      {:error, :not_running} ->
        {:error, {:not_running, tbl}}

      [] ->
        {:error, {:empty_table, tbl}}

      rows when is_list(rows) ->
        {:ok, rows}
    end
  end
end
