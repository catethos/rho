defmodule Rho.Stdlib.EffectDispatcher do
  @moduledoc """
  Dispatches `Rho.Effect.*` structs produced by tool responses to the
  per-session data table server and the session event bus.

  This is the bridge between the core runtime's effect structs and any
  consumer that wants to react to them — the LiveView demo subscribes
  to the events this dispatcher publishes, but a non-LV host (CLI,
  external app over HTTP/WS) can do the same by subscribing to
  `Rho.Events`.

  For `%Rho.Effect.Table{}`:

    1. Calls `Rho.Stdlib.DataTable.ensure_started/1` / `replace_all/3`
       / `add_rows/3` on the target named table (defaults to `"main"`).
    2. Publishes a single `:view_change` payload on
       `rho.session.<sid>.events.data_table` carrying the optional
       `schema_key` (web view key) and `mode_label`.

  The DataTable server publishes its own `:table_changed` invalidation
  event after the write — subscribers react to that to refetch the
  snapshot.

  Typically called from a session-effect applier when tool_result
  signals carry effects.
  """

  alias Rho.Stdlib.DataTable

  @type dispatch_context :: %{
          session_id: String.t(),
          agent_id: String.t()
        }

  @doc """
  Dispatch a single effect struct, publishing the appropriate signals.

  Returns `:ok`.
  """
  @spec dispatch(struct(), dispatch_context()) :: :ok
  def dispatch(%Rho.Effect.Table{} = effect, ctx) do
    session_id = ctx.session_id
    agent_id = ctx.agent_id
    table_name = effect.table_name || "main"

    # Ensure the server is up. `restart: :temporary` means we own the
    # first-start decision here rather than leaking it into `add_rows`.
    _ = DataTable.ensure_started(session_id)

    # Announce the view change (schema key + mode label) so subscribers
    # can pick the right view even though the data still lives in the
    # "main" table for now. This is a UI hint, not a data signal.
    if effect.schema_key || effect.mode_label do
      publish_view_change(session_id, agent_id, %{
        view_key: effect.schema_key,
        mode_label: effect.mode_label,
        table_name: table_name,
        metadata: effect.metadata
      })
    end

    # Canonical write: update the DataTable server. The server itself
    # publishes `:table_changed` on the `data_table` topic, which
    # subscribers react to by refetching the active snapshot.
    #
    # When `skip_write?` is set the caller has already written via
    # `RhoFrameworks.Workbench` and only wants the UI tab switch.
    _ =
      cond do
        effect.skip_write? -> :ok
        effect.append? -> DataTable.add_rows(session_id, effect.rows, table: table_name)
        true -> DataTable.replace_all(session_id, effect.rows, table: table_name)
      end

    :ok
  end

  def dispatch(%Rho.Effect.OpenWorkspace{} = effect, ctx) do
    session_id = ctx.session_id
    agent_id = ctx.agent_id

    Rho.Events.broadcast(
      session_id,
      Rho.Events.event(:workspace_open, session_id, agent_id, %{
        key: effect.key,
        surface: effect.surface
      })
    )

    :ok
  end

  def dispatch(_unknown_effect, _ctx), do: :ok

  @doc """
  Dispatch a list of effects in order.
  """
  @spec dispatch_all([struct()], dispatch_context()) :: :ok
  def dispatch_all(effects, ctx) when is_list(effects) do
    Enum.each(effects, fn effect ->
      t0 = System.monotonic_time(:microsecond)
      dispatch(effect, ctx)
      dt = System.monotonic_time(:microsecond) - t0

      :telemetry.execute(
        [:rho, :effect, :dispatch],
        %{duration_us: dt},
        %{effect_type: effect.__struct__}
      )
    end)
  end

  defp publish_view_change(session_id, agent_id, payload) do
    Rho.Events.broadcast(
      session_id,
      Rho.Events.event(:data_table, session_id, agent_id, Map.put(payload, :event, :view_change))
    )
  end
end
