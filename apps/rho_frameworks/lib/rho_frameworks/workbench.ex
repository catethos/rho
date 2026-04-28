defmodule RhoFrameworks.Workbench do
  @moduledoc """
  Domain API for editing the framework that lives in a session — the
  bundle of named tables `library`, `role_profile`, and `meta`. All
  mutations to those three tables go through this module: direct UI,
  flow nodes, and chat tools all converge here.

  The session edits exactly one framework at a time. The framework is
  implicit in `scope.session_id` and identified by table name (e.g.
  `"library:My Framework"`). Phase 1 callers still pass an explicit
  `table` argument; later phases can derive it from session state.

  Workbench wraps `DataTableOps` for mutation and reads via
  `Rho.Stdlib.DataTable` directly for snapshots. Reads never need
  provenance, so they don't go through DataTableOps.
  """

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableOps
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.Frameworks.ResearchNote
  alias RhoFrameworks.Library, as: LibraryCtx
  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.MapAccess
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Scope

  @library_default "library"
  @meta_table "meta"
  @role_profile_table "role_profile"
  @research_notes_table "research_notes"
  @combine_preview_table "combine_preview"

  @max_proficiency_level 5
  @min_proficiency_level 0

  # --- Single-skill mutations -------------------------------------------

  @doc """
  Append a single skill row to the library table. Enforces that
  `skill_name` is present and that no row with the same `skill_name`
  already exists in the table.
  """
  @spec add_skill(Scope.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_skill(%Scope{} = scope, %{} = row, opts \\ []) do
    table = Keyword.get(opts, :table, @library_default)

    with :ok <- require_field(row, :skill_name),
         :ok <- ensure_unique_skill_name(scope, table, row) do
      DataTableOps.AddSkill.run(scope, table, row)
    end
  end

  @doc "Remove a skill row by id from the library table."
  @spec remove_skill(Scope.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def remove_skill(%Scope{} = scope, id, opts \\ []) when is_binary(id) do
    table = Keyword.get(opts, :table, @library_default)
    DataTableOps.RemoveSkill.run(scope, table, id)
  end

  @doc "Rename a cluster (every row whose cluster matches `old_name`)."
  @spec rename_cluster(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{updated: non_neg_integer()}} | {:error, term()}
  def rename_cluster(%Scope{} = scope, old_name, new_name, opts \\ [])
      when is_binary(old_name) and is_binary(new_name) do
    table = Keyword.get(opts, :table, @library_default)
    DataTableOps.RenameCluster.run(scope, table, old_name, new_name)
  end

  @doc """
  Replace the meta table's single row with `fields`. Acceptable keys:
  `:name`, `:description`, `:target_roles`. Unknown keys are dropped to
  satisfy the strict schema.
  """
  @spec set_meta(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def set_meta(%Scope{} = scope, %{} = fields) do
    DataTableOps.SetMeta.run(scope, Map.take(fields, [:name, :description, :target_roles]))
  end

  @doc """
  Update a skill's `proficiency_levels` field, matched by `skill_name`.
  Each level's `level` value must be in `0..5`.
  """
  @spec set_proficiency(Scope.t(), String.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def set_proficiency(%Scope{} = scope, skill_name, levels, opts \\ [])
      when is_binary(skill_name) and is_list(levels) do
    table = Keyword.get(opts, :table, @library_default)

    with :ok <- validate_levels(levels) do
      DataTableOps.SetProficiencyLevel.run(scope, table, skill_name, levels)
    end
  end

  @doc "Stub for row reordering — emits a `:framework_mutation` event only (Phase 1)."
  @spec reorder_rows(Scope.t(), [String.t()], keyword()) :: :ok
  def reorder_rows(%Scope{} = scope, ordered_ids, opts \\ []) when is_list(ordered_ids) do
    table = Keyword.get(opts, :table, @library_default)
    DataTableOps.ReorderRows.run(scope, table, ordered_ids)
  end

  # --- Bulk mutations ---------------------------------------------------

  @doc """
  Append multiple rows to a framework table. Bypasses the per-row
  uniqueness check — callers are responsible for de-duping when
  appending bulk imports.
  """
  @spec append_rows(Scope.t(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def append_rows(%Scope{} = scope, rows, opts \\ []) when is_list(rows) do
    table = require_framework_table(opts)
    DataTableOps.AppendRows.run(scope, table, rows)
  end

  @doc "Replace every row in a framework table."
  @spec replace_rows(Scope.t(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def replace_rows(%Scope{} = scope, rows, opts \\ []) when is_list(rows) do
    table = require_framework_table(opts)
    DataTableOps.ReplaceRows.run(scope, table, rows)
  end

  @doc "Apply low-level cell changes to a framework table."
  @spec update_cells(Scope.t(), [map()], keyword()) :: :ok | {:error, term()}
  def update_cells(%Scope{} = scope, changes, opts \\ []) when is_list(changes) do
    table = require_framework_table(opts)
    DataTableOps.UpdateCells.run(scope, table, changes)
  end

  # --- Persistence boundary ---------------------------------------------

  @doc """
  Hydrate a framework from Ecto into the session's library table. The
  table name follows `Editor.table_name(lib.name)` for compatibility
  with existing tools.
  """
  @spec load_framework(Scope.t(), String.t()) ::
          {:ok, %{library: struct(), table: String.t(), count: non_neg_integer()}}
          | {:error, term()}
  def load_framework(%Scope{} = scope, library_id) when is_binary(library_id) do
    case LibraryCtx.get_library(scope.organization_id, library_id) do
      nil ->
        {:error, :not_found}

      lib ->
        rows = LibraryCtx.load_library_rows(lib.id)
        table = Editor.table_name(lib.name)
        spec = Editor.table_spec(lib.name)

        with :ok <- DataTable.ensure_table(scope.session_id, table, spec.schema),
             {:ok, inserted} <- replace_rows(scope, rows, table: table) do
          {:ok, %{library: lib, table: table, count: length(inserted)}}
        end
    end
  end

  @doc """
  Persist the session's library table back to Ecto under `library_id`.
  Delegates to `Editor.save_table` which already handles draft creation
  for published libraries.

  After the library save succeeds, archives any pinned rows from the
  session's `research_notes` named table to the `research_notes` Ecto
  table FK'd to the resulting library. Unpinned findings are discarded
  on purpose — only the user-endorsed subset is kept. The returned
  summary includes `:research_notes_saved` (0 when no panel was used).

  Set `opts[:archive_research]: false` to skip the research write
  (used by tests that don't care about notes).
  """
  @spec save_framework(Scope.t(), String.t() | nil, keyword()) ::
          {:ok,
           %{
             library: struct(),
             saved_count: non_neg_integer(),
             research_notes_saved: non_neg_integer()
           }}
          | {:error, term()}
  def save_framework(%Scope{} = scope, library_id \\ nil, opts \\ []) do
    table =
      case Keyword.fetch(opts, :table) do
        {:ok, t} -> t
        :error -> default_save_table(scope, library_id)
      end

    archive? = Keyword.get(opts, :archive_research, true)

    case Editor.save_table(%{library_id: library_id, table_name: table}, scope) do
      {:ok, %{library: lib} = result} ->
        target_id = Map.get(result, :draft_library_id) || lib.id
        notes_count = if archive?, do: archive_pinned_notes(scope, target_id), else: 0

        {:ok, Map.put(result, :research_notes_saved, notes_count)}

      other ->
        other
    end
  end

  # --- Merge two frameworks ---------------------------------------------

  @doc """
  Compute the diff between two libraries and write the conflict pairs
  into the session's `combine_preview` named table for review.

  Wraps `RhoFrameworks.Library.combine_preview/2`. Each conflict row gets
  a `resolution: "unresolved"` cell which the wizard's `:resolve_conflicts`
  step rewrites via `Workbench.update_cells/3`.

  Returns counts so the wizard can short-circuit when there are no
  conflicts (the merge step still runs, but `:resolve_conflicts` becomes
  a no-op).
  """
  @spec diff_frameworks(Scope.t(), String.t(), String.t()) ::
          {:ok,
           %{
             table_name: String.t(),
             conflict_count: non_neg_integer(),
             clean_count: non_neg_integer(),
             total: non_neg_integer()
           }}
          | {:error, term()}
  def diff_frameworks(%Scope{} = scope, library_id_a, library_id_b)
      when is_binary(library_id_a) and is_binary(library_id_b) do
    with :ok <- ensure_library_exists(scope.organization_id, library_id_a),
         :ok <- ensure_library_exists(scope.organization_id, library_id_b) do
      {:ok, %{conflicts: conflicts, stats: stats}} =
        LibraryCtx.combine_preview(scope.organization_id, [library_id_a, library_id_b])

      rows = Enum.map(conflicts, &conflict_to_row/1)

      with :ok <-
             DataTable.ensure_table(
               scope.session_id,
               @combine_preview_table,
               DataTableSchemas.combine_preview_schema()
             ),
           {:ok, _} <- replace_rows(scope, rows, table: @combine_preview_table) do
        {:ok,
         %{
           table_name: @combine_preview_table,
           conflict_count: length(conflicts),
           clean_count: stats.clean,
           total: stats.total
         }}
      end
    end
  end

  defp ensure_library_exists(org_id, library_id) do
    case LibraryCtx.get_library(org_id, library_id) do
      %{} -> :ok
      nil -> {:error, {:library_not_found, library_id}}
    end
  end

  @doc """
  Persist a merged library composed from two source libraries with the
  user's per-conflict resolutions. Wraps
  `RhoFrameworks.Library.combine_commit/5` and then hydrates the new
  library into a session library table so `:save` (no-op) and the table
  review UI both see the result.

  Resolutions arrive in the schema-vocab `merge_a | merge_b | keep_both`
  produced by the conflict UI; this function translates them to the
  `combine_commit` shape (`pick`/`merge`/`keep_both` actions).
  """
  @spec merge_frameworks(Scope.t(), String.t(), String.t(), String.t(), [map()]) ::
          {:ok,
           %{
             library_id: String.t(),
             library_name: String.t(),
             table_name: String.t(),
             skill_count: non_neg_integer()
           }}
          | {:error, term()}
  def merge_frameworks(
        %Scope{} = scope,
        library_id_a,
        library_id_b,
        new_name,
        resolutions
      )
      when is_binary(library_id_a) and is_binary(library_id_b) and is_binary(new_name) and
             is_list(resolutions) do
    translated = Enum.map(resolutions, &translate_resolution/1) |> Enum.reject(&is_nil/1)

    case LibraryCtx.combine_commit(
           scope.organization_id,
           [library_id_a, library_id_b],
           new_name,
           translated
         ) do
      {:ok, %{library: lib, skill_count: count}} ->
        case load_framework(scope, lib.id) do
          {:ok, %{table: table}} ->
            {:ok,
             %{
               library_id: lib.id,
               library_name: lib.name,
               table_name: table,
               skill_count: count
             }}

          {:error, _} = err ->
            err
        end

      {:error, _, _, _} = err ->
        {:error, err}

      {:error, _} = err ->
        err
    end
  end

  # --- Snapshots --------------------------------------------------------

  @doc "Return per-table snapshots for the framework's three tables."
  @spec snapshot(Scope.t(), keyword()) :: %{tables: map()}
  def snapshot(%Scope{} = scope, opts \\ []) do
    library_table = Keyword.get(opts, :library_table, @library_default)

    %{
      tables: %{
        library: read_rows_or_empty(scope.session_id, library_table),
        role_profile: read_rows_or_empty(scope.session_id, @role_profile_table),
        meta: read_rows_or_empty(scope.session_id, @meta_table)
      }
    }
  end

  # --- Internal helpers -------------------------------------------------

  defp require_framework_table(opts) do
    case Keyword.fetch(opts, :table) do
      {:ok, t} when is_binary(t) -> t
      :error -> raise ArgumentError, "Workbench bulk ops require a :table option"
    end
  end

  defp require_field(row, field) do
    case MapAccess.get(row, field) do
      nil -> {:error, {:missing, field}}
      "" -> {:error, {:missing, field}}
      _ -> :ok
    end
  end

  defp ensure_unique_skill_name(%Scope{} = scope, table, row) do
    name = MapAccess.get(row, :skill_name)
    rows = DataTable.get_rows(scope.session_id, table: table, filter: %{skill_name: name})

    case rows do
      {:error, :not_running} -> :ok
      [] -> :ok
      list when is_list(list) -> {:error, {:duplicate_skill_name, name}}
    end
  end

  defp validate_levels(levels) do
    Enum.reduce_while(levels, :ok, fn lvl, _ ->
      case MapAccess.get(lvl, :level) do
        n when is_integer(n) and n >= @min_proficiency_level and n <= @max_proficiency_level ->
          {:cont, :ok}

        bad ->
          {:halt, {:error, {:invalid_level, bad}}}
      end
    end)
  end

  defp default_save_table(%Scope{} = scope, library_id) do
    case library_id && LibraryCtx.get_library(scope.organization_id, library_id) do
      %{name: name} -> Editor.table_name(name)
      _ -> @library_default
    end
  end

  defp read_rows_or_empty(session_id, table) do
    case DataTable.get_rows(session_id, table: table) do
      rows when is_list(rows) -> rows
      _ -> []
    end
  end

  # --- Research notes archive -------------------------------------------

  defp archive_pinned_notes(%Scope{session_id: nil}, _library_id), do: 0

  defp archive_pinned_notes(%Scope{session_id: sid}, library_id) when is_binary(library_id) do
    sid
    |> read_rows_or_empty(@research_notes_table)
    |> Enum.filter(&row_pinned?/1)
    |> Enum.map(&row_to_note_attrs(&1, library_id))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        0

      attrs_list ->
        Enum.reduce(attrs_list, 0, fn attrs, acc ->
          case %ResearchNote{} |> ResearchNote.changeset(attrs) |> Repo.insert() do
            {:ok, _} -> acc + 1
            {:error, _} -> acc
          end
        end)
    end
  end

  defp archive_pinned_notes(_, _), do: 0

  defp row_pinned?(row) when is_map(row) do
    case MapAccess.get(row, :pinned) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp row_to_note_attrs(row, library_id) do
    fact = MapAccess.get(row, :fact)
    source = MapAccess.get(row, :source)

    if blank?(fact) or blank?(source) do
      nil
    else
      %{
        library_id: library_id,
        source: source,
        fact: fact,
        tag: MapAccess.get(row, :tag),
        inserted_by: source_to_inserted_by(source)
      }
    end
  end

  defp source_to_inserted_by("user"), do: "user"
  defp source_to_inserted_by(_), do: "agent"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # --- Conflict-row helpers ---------------------------------------------

  defp conflict_to_row(%{skill_a: a, skill_b: b, confidence: confidence}) do
    %{
      category: a.category || b.category || "",
      confidence: Atom.to_string(confidence),
      skill_a_id: a.id,
      skill_a_name: a.name,
      skill_a_description: Map.get(a, :description) || "",
      skill_a_source: a.source_library_name,
      skill_a_levels: Map.get(a, :level_count, 0),
      skill_a_roles: Map.get(a, :role_count, 0),
      skill_b_id: b.id,
      skill_b_name: b.name,
      skill_b_description: Map.get(b, :description) || "",
      skill_b_source: b.source_library_name,
      skill_b_levels: Map.get(b, :level_count, 0),
      skill_b_roles: Map.get(b, :role_count, 0),
      resolution: "unresolved"
    }
  end

  # Translate the resolution-vocab the conflict UI writes (`merge_a`,
  # `merge_b`, `keep_both`, `unresolved`) into the canonical
  # `combine_commit/5` shape. Unresolved rows are dropped — `combine_commit`
  # treats absent resolutions as "first source wins via slug-dedup", which
  # is the documented fallback when a user advances without picking.
  defp translate_resolution(%{} = res) do
    a_id = MapAccess.get(res, :skill_a_id)
    b_id = MapAccess.get(res, :skill_b_id)
    resolution = MapAccess.get(res, :resolution)

    case {resolution, a_id, b_id} do
      {"merge_a", a, b} when is_binary(a) and is_binary(b) ->
        %{"skill_a_id" => a, "skill_b_id" => b, "action" => "merge", "keep" => a}

      {"merge_b", a, b} when is_binary(a) and is_binary(b) ->
        %{"skill_a_id" => a, "skill_b_id" => b, "action" => "merge", "keep" => b}

      {"keep_both", a, b} when is_binary(a) and is_binary(b) ->
        %{"skill_a_id" => a, "skill_b_id" => b, "action" => "keep_both"}

      _ ->
        nil
    end
  end

  # --- Table-name accessors (used by migrating tools) -------------------

  @doc false
  def role_profile_table, do: @role_profile_table

  @doc false
  def meta_table, do: @meta_table

  @doc false
  def library_default_table, do: @library_default

  @doc false
  def research_notes_table, do: @research_notes_table

  @doc false
  def combine_preview_table, do: @combine_preview_table
end
