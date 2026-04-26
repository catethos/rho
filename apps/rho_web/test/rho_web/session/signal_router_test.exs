defmodule RhoWeb.Session.SignalRouterTest do
  use ExUnit.Case, async: true

  alias RhoWeb.Session.SignalRouter
  alias RhoWeb.Projections.DataTableProjection

  # Build a minimal assigns map with __changed__ tracking for Phoenix.Component.assign/3
  defp build_socket(extra \\ %{}) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          ws_states: %{data_table: DataTableProjection.init()},
          workspaces: workspaces()
        },
        extra
      )

    struct!(Phoenix.LiveView.Socket, assigns: assigns)
  end

  defp workspaces do
    %{
      data_table: %{
        label: "Skills Editor",
        icon: "table",
        projection: DataTableProjection
      }
    }
  end

  describe "read_ws_state/2" do
    test "reads initial snapshot-cache state" do
      socket = build_socket()
      assert SignalRouter.read_ws_state(socket, :data_table) == DataTableProjection.init()
    end

    test "returns nil for unknown workspace" do
      socket = build_socket()
      assert SignalRouter.read_ws_state(socket, :canvas) == nil
    end
  end

  describe "write_ws_state/3" do
    test "writes and reads back state" do
      socket = build_socket()
      new_state = Map.put(DataTableProjection.init(), :active_table, "library")
      socket = SignalRouter.write_ws_state(socket, :data_table, new_state)
      assert SignalRouter.read_ws_state(socket, :data_table) == new_state
    end

    test "preserves other workspace states" do
      socket =
        build_socket(%{ws_states: %{data_table: DataTableProjection.init(), other: %{x: 1}}})

      new_state = Map.put(DataTableProjection.init(), :active_table, "library")
      socket = SignalRouter.write_ws_state(socket, :data_table, new_state)
      assert SignalRouter.read_ws_state(socket, :other) == %{x: 1}
    end
  end

  describe "DataTable stub projection" do
    test "handles?/1 is false for all event kinds" do
      refute DataTableProjection.handles?(:data_table_rows_delta)
      refute DataTableProjection.handles?(:text_delta)
    end

    test "reduce/2 is a no-op" do
      state = DataTableProjection.init()
      signal = %{kind: :whatever, data: %{}}
      assert DataTableProjection.reduce(state, signal) == state
    end
  end
end
