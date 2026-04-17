defmodule RhoWeb.Session.EffectDispatcher do
  @moduledoc """
  Dispatches `Rho.Effect.*` structs produced by tool responses to the
  per-session data table server and the session signal bus.

  This is the bridge between the core runtime's effect structs and the
  web layer. For `%Rho.Effect.Table{}`:

    1. Calls `Rho.Stdlib.DataTable.ensure_started/1` / `replace_all/3`
       / `add_rows/3` on the target named table (defaults to `"main"`).
    2. Publishes a single `:view_change` payload on
       `rho.session.<sid>.events.data_table` carrying the optional
       `schema_key` (web view key) and `mode_label`. The LiveView
       uses this to select the correct web schema and title.

  The DataTable server publishes its own `:table_changed` invalidation
  event after the write — the LiveView reacts to that to refetch the
  snapshot. There is no second legacy row-delta signal stream.

  Called from `SessionEffects.apply/2` when tool_result signals carry
  effects.
  """

  alias Rho.Comms
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

    # Announce the view change (schema key + mode label) so the LV can
    # pick the right web schema even though the data still lives in
    # the "main" table for now. This is a UI hint, not a data signal.
    if effect.schema_key || effect.mode_label do
      publish_view_change(session_id, agent_id, %{
        view_key: effect.schema_key,
        mode_label: effect.mode_label,
        table_name: table_name,
        metadata: effect.metadata
      })
    end

    # Canonical write: update the DataTable server. The server itself
    # publishes `:table_changed` on the `data_table` topic, which the
    # LiveView reacts to by refetching the active snapshot.
    _ =
      if effect.append? do
        DataTable.add_rows(session_id, effect.rows, table: table_name)
      else
        DataTable.replace_all(session_id, effect.rows, table: table_name)
      end

    :ok
  end

  def dispatch(%Rho.Effect.OpenWorkspace{} = effect, ctx) do
    session_id = ctx.session_id
    agent_id = ctx.agent_id

    Comms.publish(
      "rho.session.#{session_id}.events.workspace_open",
      %{
        session_id: session_id,
        agent_id: agent_id,
        key: effect.key,
        surface: effect.surface
      },
      source: "/session/#{session_id}/agent/#{agent_id}"
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
    topic = "rho.session.#{session_id}.events.data_table"

    Comms.publish(
      topic,
      Map.merge(payload, %{
        event: :view_change,
        session_id: session_id,
        agent_id: agent_id
      }),
      source: "/session/#{session_id}/agent/#{agent_id}"
    )
  end
end
