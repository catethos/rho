defmodule Rho.Mounts.SpreadsheetStore do
  @moduledoc """
  ETS-backed row store for bulk-imported spreadsheet data.

  Rows are stored per session. The LiveView only loads rows for expanded groups
  into its assigns, keeping the socket lightweight even with 25K+ rows.
  """

  @table :rho_spreadsheet_store

  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Store rows for a session. Each row is stored as {session_id, row}."
  def put_rows(session_id, rows) do
    ensure_table()
    # Clear existing rows for this session first
    :ets.match_delete(@table, {session_id, :_})

    entries = Enum.map(rows, fn row -> {session_id, row} end)
    :ets.insert(@table, entries)
    :ok
  end

  @doc "Get all rows for a session."
  def all_rows(session_id) do
    ensure_table()

    @table
    |> :ets.lookup(session_id)
    |> Enum.map(fn {_sid, row} -> row end)
  end

  @doc "Get rows matching a role (for role view) or category (for category view)."
  def rows_for_group(session_id, :role, group_name) do
    all_rows(session_id)
    |> Enum.filter(fn row ->
      role = row[:role] || ""
      if group_name == "Unassigned", do: role == "", else: role == group_name
    end)
  end

  def rows_for_group(session_id, :category, group_name) do
    all_rows(session_id)
    |> Enum.filter(fn row -> (row[:category] || "") == group_name end)
  end

  @doc """
  Build a summary of all groups without loading full row data.
  Returns a list of {group_name, %{row_count: N, skill_count: M}} tuples.
  """
  def group_summary(session_id, :role) do
    all_rows(session_id)
    |> Enum.group_by(fn row ->
      role = row[:role] || ""
      if role == "", do: "Unassigned", else: role
    end)
    |> Enum.map(fn {group, rows} ->
      skills = rows |> Enum.map(& &1[:skill_name]) |> Enum.uniq() |> length()
      {group, %{row_count: length(rows), skill_count: skills}}
    end)
    |> Enum.sort_by(fn {name, _} -> if name == "Unassigned", do: "zzz", else: name end)
  end

  def group_summary(session_id, :category) do
    all_rows(session_id)
    |> Enum.group_by(fn row -> row[:category] || "" end)
    |> Enum.map(fn {group, rows} ->
      skills = rows |> Enum.map(& &1[:skill_name]) |> Enum.uniq() |> length()
      {group, %{row_count: length(rows), skill_count: skills}}
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  @doc "Total row count for a session."
  def row_count(session_id) do
    ensure_table()
    :ets.match(@table, {session_id, :_}) |> length()
  end

  @doc "Clear all rows for a session."
  def clear(session_id) do
    ensure_table()
    :ets.match_delete(@table, {session_id, :_})
    :ok
  end

  @doc "Check if a session has stored rows."
  def has_rows?(session_id) do
    ensure_table()
    :ets.member(@table, session_id)
  end
end
