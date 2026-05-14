defmodule Rho.Stdlib.DataTable.ActiveViewListenerTest do
  use ExUnit.Case, async: false

  alias Rho.Events
  alias Rho.Events.Event
  alias Rho.Stdlib.DataTable

  setup do
    session_id = "avl_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> DataTable.stop(session_id) end)
    {:ok, session_id: session_id}
  end

  defp wait_for(fun, timeout \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("wait_for timed out")
        else
          Process.sleep(10)
          do_wait_for(fun, deadline)
        end
    end
  end

  describe "view_focus -> set_active_table" do
    test "updates server's active_table on :view_focus", %{session_id: sid} do
      DataTable.ensure_started(sid)
      assert DataTable.get_active_table(sid) == nil

      # The listener subscribes to the session topic on :agent_started.
      Events.broadcast_lifecycle(%Event{
        kind: :agent_started,
        session_id: sid,
        timestamp: System.monotonic_time(:millisecond),
        data: %{primary?: true}
      })

      # Give the listener a tick to process the lifecycle event before we
      # broadcast the session-scoped focus event.
      Process.sleep(20)

      Events.broadcast(sid, %Event{
        kind: :view_focus,
        session_id: sid,
        timestamp: System.monotonic_time(:millisecond),
        data: %{table_name: "library", row_count: 3},
        source: :user
      })

      wait_for(fn ->
        case DataTable.get_active_table(sid) do
          "library" -> {:ok, "library"}
          _ -> :pending
        end
      end)
    end

    test "ignores :view_focus for sessions whose primary agent stopped",
         %{session_id: sid} do
      DataTable.ensure_started(sid)

      # Subscribe.
      Events.broadcast_lifecycle(%Event{
        kind: :agent_started,
        session_id: sid,
        timestamp: System.monotonic_time(:millisecond),
        data: %{primary?: true}
      })

      Process.sleep(20)

      # Stop.
      Events.broadcast_lifecycle(%Event{
        kind: :agent_stopped,
        session_id: sid,
        timestamp: System.monotonic_time(:millisecond),
        data: %{primary?: true}
      })

      Process.sleep(20)

      # This focus event should NOT be picked up.
      Events.broadcast(sid, %Event{
        kind: :view_focus,
        session_id: sid,
        timestamp: System.monotonic_time(:millisecond),
        data: %{table_name: "library", row_count: 0},
        source: :user
      })

      Process.sleep(50)

      assert DataTable.get_active_table(sid) == nil
    end

    test "row_selection event populates server selection", %{session_id: sid} do
      DataTable.ensure_started(sid)
      {:ok, [r1, r2]} = DataTable.add_rows(sid, [%{name: "a"}, %{name: "b"}])

      Events.broadcast_lifecycle(%Event{
        kind: :agent_started,
        session_id: sid,
        timestamp: System.monotonic_time(:millisecond),
        data: %{primary?: true}
      })

      Process.sleep(20)

      Events.broadcast(sid, %Event{
        kind: :row_selection,
        session_id: sid,
        timestamp: System.monotonic_time(:millisecond),
        data: %{table_name: "main", row_ids: [r1.id, r2.id]},
        source: :user
      })

      wait_for(fn ->
        case DataTable.get_selection(sid, "main") do
          [_, _] = ids -> {:ok, ids}
          _ -> :pending
        end
      end)
    end

    test "tolerates :view_focus when DataTable.Server is down", %{session_id: sid} do
      # Don't start the server. set_active_table returns {:error, :not_running}
      # which the listener swallows. The listener must not crash.
      Events.broadcast_lifecycle(%Event{
        kind: :agent_started,
        session_id: sid,
        timestamp: System.monotonic_time(:millisecond),
        data: %{primary?: true}
      })

      Process.sleep(20)

      Events.broadcast(sid, %Event{
        kind: :view_focus,
        session_id: sid,
        timestamp: System.monotonic_time(:millisecond),
        data: %{table_name: "library", row_count: 0},
        source: :user
      })

      Process.sleep(20)

      pid = Process.whereis(Rho.Stdlib.DataTable.ActiveViewListener)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
end
