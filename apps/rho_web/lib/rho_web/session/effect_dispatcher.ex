defmodule RhoWeb.Session.EffectDispatcher do
  @moduledoc """
  Dispatches `Rho.Effect.*` structs produced by tool responses to the
  appropriate signal bus topics.

  This is the bridge between the core runtime's effect structs and the
  web layer's signal-driven projections. Each effect type maps to one or
  more signal bus publishes that existing workspace projections already
  handle.

  Called from `SessionEffects.apply/2` when tool_result signals carry
  effects.
  """

  alias Rho.Comms
  alias Rho.Stdlib.Plugins.DataTable, as: DT

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

    # Schema change if schema_key or columns are provided
    if effect.schema_key || effect.columns != [] do
      payload =
        %{}
        |> maybe_put(:schema_key, effect.schema_key)
        |> maybe_put(:mode_label, effect.mode_label)
        |> maybe_put_non_empty(:columns, effect.columns)

      DT.publish_event(session_id, agent_id, :schema_change, payload)
    end

    if effect.append? do
      # Append mode: stream rows progressively
      DT.stream_rows_progressive(effect.rows, :add, session_id, agent_id)
    else
      # Replace mode: clear then stream
      DT.publish_event(session_id, agent_id, :replace_all, %{})
      DT.stream_rows_progressive(effect.rows, :add, session_id, agent_id)
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_non_empty(map, _key, []), do: map
  defp maybe_put_non_empty(map, key, value), do: Map.put(map, key, value)
end
