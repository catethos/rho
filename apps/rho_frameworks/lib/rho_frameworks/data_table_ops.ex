defmodule RhoFrameworks.DataTableOps do
  @moduledoc """
  Internal mutation helpers for `RhoFrameworks.Workbench`. **Not a public
  API** — call `Workbench.*` instead. Each op:

    1. Sets `:rho_source` in the calling process dictionary so
       `Rho.Stdlib.DataTable.Server` can stamp the coarse `:data_table`
       invalidation event.
    2. Calls the underlying `Rho.Stdlib.DataTable` mutation.
    3. Stamps `_source` (and optional `_reason`) onto inserted rows so
       the renderer can show provenance icons without a side channel.
    4. Emits a richer `:framework_mutation` event carrying `op`,
       `table`, `payload`, plus `source`/`reason` from the scope.
  """

  alias Rho.Events
  alias Rho.Events.Event
  alias RhoFrameworks.Scope

  @type op ::
          :add_skill
          | :remove_skill
          | :rename_cluster
          | :set_meta
          | :set_proficiency_level
          | :reorder_rows
          | :append_rows
          | :replace_rows
          | :update_cells

  @doc """
  Run `fun.()` with `:rho_source` set in the process dictionary, restoring
  the prior value afterward. The `Server` reads this when publishing its
  invalidation event so the coarse `:data_table` event also carries
  provenance.
  """
  @spec with_source(Scope.t(), (-> result)) :: result when result: var
  def with_source(%Scope{source: source}, fun) when is_function(fun, 0) do
    prior = Process.get(:rho_source)
    Process.put(:rho_source, source)

    try do
      fun.()
    after
      if is_nil(prior) do
        Process.delete(:rho_source)
      else
        Process.put(:rho_source, prior)
      end
    end
  end

  @doc "Stamp `_source` (and optional `_reason`) onto a row map."
  @spec stamp(map(), Scope.t()) :: map()
  def stamp(row, %Scope{source: source, reason: reason}) when is_map(row) do
    row
    |> put_if_absent(:_source, source_to_string(source))
    |> put_if_absent(:_reason, reason)
  end

  @doc "Stamp every row in a list."
  @spec stamp_all([map()], Scope.t()) :: [map()]
  def stamp_all(rows, %Scope{} = scope) when is_list(rows) do
    Enum.map(rows, &stamp(&1, scope))
  end

  @doc """
  Broadcast a `:framework_mutation` event carrying op/table/payload plus
  scope provenance. The session's coarse `:data_table` invalidation
  event still fires from the Server; this is the richer parallel signal
  for subscribers that care about provenance.
  """
  @spec emit(Scope.t(), op(), String.t(), map()) :: :ok | {:error, term()}
  def emit(%Scope{} = scope, op, table, payload)
      when is_atom(op) and is_binary(table) and is_map(payload) do
    Events.broadcast(scope.session_id, %Event{
      kind: :framework_mutation,
      session_id: scope.session_id,
      agent_id: nil,
      timestamp: System.monotonic_time(:millisecond),
      source: scope.source,
      reason: scope.reason,
      data: %{op: op, table: table, payload: payload}
    })
  end

  defp put_if_absent(map, _key, nil), do: map

  defp put_if_absent(map, key, value) do
    cond do
      Map.has_key?(map, key) -> map
      Map.has_key?(map, to_string(key)) -> map
      true -> Map.put(map, key, value)
    end
  end

  defp source_to_string(nil), do: nil
  defp source_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp source_to_string(s) when is_binary(s), do: s
end
