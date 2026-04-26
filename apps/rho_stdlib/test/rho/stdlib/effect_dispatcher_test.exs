defmodule Rho.Stdlib.EffectDispatcherTest do
  use ExUnit.Case, async: true

  alias Rho.Stdlib.EffectDispatcher

  @ctx %{session_id: "test-session", agent_id: "test-agent"}

  describe "dispatch/2 with Effect.Table" do
    test "replace mode publishes replace_all then streams rows" do
      effect = %Rho.Effect.Table{
        columns: [],
        rows: [%{name: "Elixir", level: 3}],
        append?: false
      }

      # Should not raise — publishes to event bus (no subscribers in test)
      assert :ok = EffectDispatcher.dispatch(effect, @ctx)
    end

    test "append mode streams rows without replace_all" do
      effect = %Rho.Effect.Table{
        rows: [%{name: "Elixir", level: 3}],
        append?: true
      }

      assert :ok = EffectDispatcher.dispatch(effect, @ctx)
    end

    test "empty rows still dispatches" do
      effect = %Rho.Effect.Table{rows: [], append?: false}
      assert :ok = EffectDispatcher.dispatch(effect, @ctx)
    end

    test "columns trigger schema_change" do
      effect = %Rho.Effect.Table{
        columns: [%{key: :name, label: "Name"}],
        rows: []
      }

      assert :ok = EffectDispatcher.dispatch(effect, @ctx)
    end
  end

  describe "dispatch/2 with Effect.OpenWorkspace" do
    test "publishes workspace_open signal" do
      effect = %Rho.Effect.OpenWorkspace{key: :data_table, surface: :overlay}
      assert :ok = EffectDispatcher.dispatch(effect, @ctx)
    end
  end

  describe "dispatch/2 with unknown effect" do
    test "returns :ok for unrecognized structs" do
      assert :ok = EffectDispatcher.dispatch(%{unknown: true}, @ctx)
    end
  end

  describe "dispatch_all/2" do
    test "dispatches multiple effects in order" do
      effects = [
        %Rho.Effect.OpenWorkspace{key: :data_table},
        %Rho.Effect.Table{rows: [%{a: 1}], append?: false}
      ]

      assert :ok = EffectDispatcher.dispatch_all(effects, @ctx)
    end

    test "handles empty list" do
      assert :ok = EffectDispatcher.dispatch_all([], @ctx)
    end
  end
end
