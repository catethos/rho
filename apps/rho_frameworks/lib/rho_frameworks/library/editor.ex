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
