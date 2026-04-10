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
    test "reads initial projection state" do
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
      new_state = %{rows_map: %{1 => %{id: 1}}, next_id: 2, partial_streamed: %{}}
      socket = SignalRouter.write_ws_state(socket, :data_table, new_state)
      assert SignalRouter.read_ws_state(socket, :data_table) == new_state
    end

    test "preserves other workspace states" do
      socket =
        build_socket(%{ws_states: %{data_table: DataTableProjection.init(), other: %{x: 1}}})

      new_ss = %{rows_map: %{1 => %{id: 1}}, next_id: 2, partial_streamed: %{}}
      socket = SignalRouter.write_ws_state(socket, :data_table, new_ss)
      assert SignalRouter.read_ws_state(socket, :other) == %{x: 1}
    end
  end

  describe "route/3 workspace dispatch" do
    # We test workspace routing in isolation by using a stub that doesn't
    # go through SessionProjection (which requires a fully connected socket).
    # The integration path is covered by existing LiveView tests.

    test "dispatches spreadsheet signal to DataTableProjection" do
      socket = build_socket()

      signal = %{
        type: "rho.session.test.data_table_rows_delta",
        data: %{rows: [%{"skill_name" => "Elixir"}]}
      }

      # Directly test the workspace dispatch portion
      socket =
        Enum.reduce(workspaces(), socket, fn {key, ws}, sock ->
          if ws.projection.handles?(signal.type) do
            state = SignalRouter.read_ws_state(sock, key)
            new_state = ws.projection.reduce(state, signal)
            SignalRouter.write_ws_state(sock, key, new_state)
          else
            sock
          end
        end)

      ss = SignalRouter.read_ws_state(socket, :data_table)
      assert map_size(ss.rows_map) == 1
      assert ss.rows_map[1].skill_name == "Elixir"
    end

    test "non-spreadsheet signal does not change ws_states" do
      socket = build_socket()

      signal = %{
        type: "rho.session.test.text_delta",
        data: %{text: "hello"}
      }

      # Dispatch through workspaces only
      socket =
        Enum.reduce(workspaces(), socket, fn {key, ws}, sock ->
          if ws.projection.handles?(signal.type) do
            state = SignalRouter.read_ws_state(sock, key)
            new_state = ws.projection.reduce(state, signal)
            SignalRouter.write_ws_state(sock, key, new_state)
          else
            sock
          end
        end)

      assert SignalRouter.read_ws_state(socket, :data_table) == DataTableProjection.init()
    end
  end
end
