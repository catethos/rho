defmodule Rho.LLM.AdmissionTest do
  use ExUnit.Case, async: false

  alias Rho.LLM.Admission

  # Each test starts an isolated admission server with a tiny capacity
  # so behavior under saturation is easy to trigger.

  setup do
    # Terminate the app-supervised instance (doesn't auto-restart), start
    # a fresh one with tiny capacity via start_supervised! (torn down
    # between tests), then restart the app-level one on exit.
    :ok = Supervisor.terminate_child(Rho.Supervisor, Admission)

    on_exit(fn ->
      {:ok, _} = Supervisor.restart_child(Rho.Supervisor, Admission)
    end)

    start_supervised!({Admission, capacity: 2})
    :ok
  end

  test "acquire/release holds and frees slots" do
    assert :ok = Admission.acquire(1_000)
    assert %{in_flight: 1, capacity: 2, waiting: 0} = Admission.stats()
    :ok = Admission.release()
    assert %{in_flight: 0, waiting: 0} = Admission.stats()
  end

  test "with_slot releases on normal return" do
    result = Admission.with_slot(fn -> :return_value end, 1_000)
    assert result == :return_value
    assert %{in_flight: 0} = Admission.stats()
  end

  test "with_slot releases when fun raises" do
    assert_raise RuntimeError, "boom", fn ->
      Admission.with_slot(fn -> raise "boom" end, 1_000)
    end

    assert %{in_flight: 0} = Admission.stats()
  end

  test "callers queue when capacity is saturated" do
    parent = self()

    # Fill both slots with long-held tokens held by spawned tasks.
    holder_1 =
      spawn(fn ->
        :ok = Admission.acquire(1_000)
        send(parent, :holder_1_acquired)
        receive do: (:release -> Admission.release())
      end)

    holder_2 =
      spawn(fn ->
        :ok = Admission.acquire(1_000)
        send(parent, :holder_2_acquired)
        receive do: (:release -> Admission.release())
      end)

    assert_receive :holder_1_acquired, 500
    assert_receive :holder_2_acquired, 500

    # Third acquirer must queue. Keep it alive until we explicitly
    # release so we can observe the promoted-slot state.
    waiter =
      spawn(fn ->
        result = Admission.acquire(5_000)
        send(parent, {:waiter_result, result})
        receive do: (:release -> Admission.release())
      end)

    Process.sleep(100)
    assert %{in_flight: 2, waiting: 1} = Admission.stats()

    # Release one — waiter should be promoted.
    send(holder_1, :release)
    assert_receive {:waiter_result, :ok}, 1_000

    # Cleanup: holder_2 releases cleanly; waiter still holds its
    # promoted slot.
    send(holder_2, :release)
    Process.sleep(50)
    assert %{in_flight: 1} = Admission.stats()

    # Kill the waiter — monitor should reclaim its slot.
    Process.exit(waiter, :kill)
    Process.sleep(50)
    assert %{in_flight: 0} = Admission.stats()
  end

  test "acquire timeout returns error and cleans up queue" do
    # Saturate capacity.
    for _ <- 1..2 do
      spawn_link(fn ->
        :ok = Admission.acquire(1_000)
        Process.sleep(:infinity)
      end)
    end

    Process.sleep(50)
    assert %{in_flight: 2} = Admission.stats()

    # Short timeout should hit acquire_timeout.
    assert {:error, :acquire_timeout} = Admission.acquire(100)

    # Queue should be empty after cancel (no ghost waiter).
    Process.sleep(50)
    assert %{waiting: 0} = Admission.stats()
  end

  test "dead holder reclaims slot via monitor" do
    holder =
      spawn(fn ->
        :ok = Admission.acquire(1_000)
        Process.sleep(:infinity)
      end)

    Process.sleep(50)
    assert %{in_flight: 1} = Admission.stats()

    Process.exit(holder, :kill)
    Process.sleep(50)
    assert %{in_flight: 0} = Admission.stats()
  end

  describe "telemetry" do
    setup do
      handler_id = {:admission_test, self()}

      :telemetry.attach_many(
        handler_id,
        [
          [:rho, :llm, :admission, :acquire],
          [:rho, :llm, :admission, :release],
          [:rho, :llm, :admission, :queued],
          [:rho, :llm, :admission, :timeout]
        ],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "immediate acquire emits :acquire with wait_ms=0 and source=:immediate" do
      :ok = Admission.acquire(1_000)

      assert_receive {:telemetry, [:rho, :llm, :admission, :acquire], measurements, metadata},
                     500

      assert measurements.wait_ms == 0
      assert measurements.in_flight == 1
      assert measurements.capacity == 2
      assert metadata.source == :immediate

      Admission.release()

      assert_receive {:telemetry, [:rho, :llm, :admission, :release], r_meas, r_meta}, 500
      assert r_meas.in_flight == 0
      assert r_meta.reason == :release
    end

    test "queued then promoted emits :queued and :acquire with wait_ms>0" do
      parent = self()

      # Fill capacity. Use plain spawn (no link) so exits don't cascade
      # into the test process.
      holder_pids =
        for _ <- 1..2 do
          spawn(fn ->
            :ok = Admission.acquire(1_000)
            send(parent, :held)
            receive do: (:release -> Admission.release())
          end)
        end

      assert_receive :held, 200
      assert_receive :held, 200

      # Drain the two :acquire events for the holders.
      assert_receive {:telemetry, [:rho, :llm, :admission, :acquire], _, _}, 200
      assert_receive {:telemetry, [:rho, :llm, :admission, :acquire], _, _}, 200

      # Third caller queues.
      waiter =
        spawn(fn ->
          :ok = Admission.acquire(5_000)
          send(parent, :promoted)
          receive do: (:release -> Admission.release())
        end)

      assert_receive {:telemetry, [:rho, :llm, :admission, :queued], q_meas, q_meta}, 500
      assert q_meas.queue_depth == 1
      assert q_meta.pid == waiter

      # Release one holder voluntarily -> waiter promoted.
      [first_holder | _] = holder_pids
      Process.sleep(50)
      send(first_holder, :release)

      assert_receive :promoted, 1_000

      # :release from the voluntary release (reason :release)
      assert_receive {:telemetry, [:rho, :llm, :admission, :release], _, %{reason: :release}},
                     500

      # :acquire for the waiter with source :promoted and nonzero wait
      assert_receive {:telemetry, [:rho, :llm, :admission, :acquire], ack_meas,
                      %{source: :promoted, pid: ^waiter}},
                     500

      assert ack_meas.wait_ms > 0
    end

    test "acquire timeout emits :timeout event" do
      # Saturate
      for _ <- 1..2 do
        spawn_link(fn ->
          :ok = Admission.acquire(1_000)
          Process.sleep(:infinity)
        end)
      end

      # Drain :acquire events
      Process.sleep(50)
      flush_telemetry()

      assert {:error, :acquire_timeout} = Admission.acquire(100)

      assert_receive {:telemetry, [:rho, :llm, :admission, :timeout], measurements, metadata},
                     500

      assert measurements.wait_ms >= 50
      assert metadata.pid == self()
    end
  end

  # Drain any pending telemetry messages from the mailbox.
  defp flush_telemetry do
    receive do
      {:telemetry, _, _, _} -> flush_telemetry()
    after
      0 -> :ok
    end
  end
end
