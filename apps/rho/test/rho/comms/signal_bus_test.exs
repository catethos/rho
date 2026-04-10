defmodule Rho.Comms.SignalBusTest do
  @moduledoc """
  Tests for signal metadata enrichment in Rho.Comms.SignalBus.
  """

  use ExUnit.Case, async: false

  alias Rho.Comms.SignalBus

  describe "publish/3 signal metadata" do
    test "signals carry event_id (UUID) and emitted_at (millisecond timestamp)" do
      # Subscribe to a test pattern
      {:ok, _sub_id} = SignalBus.subscribe("rho.test.metadata.*")

      before_ms = System.system_time(:millisecond)
      :ok = SignalBus.publish("rho.test.metadata.check", %{hello: "world"})
      after_ms = System.system_time(:millisecond)

      assert_receive {:signal, %Jido.Signal{} = signal}, 1_000

      # event_id comes from the signal's id field (UUID)
      assert is_binary(signal.id)
      assert byte_size(signal.id) > 0

      # emitted_at is in extensions as a millisecond timestamp
      emitted_at = signal.extensions["emitted_at"]
      assert is_integer(emitted_at)
      assert emitted_at >= before_ms
      assert emitted_at <= after_ms
    end

    test "emitted_at is preserved alongside correlation_id in extensions" do
      {:ok, _sub_id} = SignalBus.subscribe("rho.test.metadata.combo.*")

      :ok =
        SignalBus.publish("rho.test.metadata.combo.check", %{x: 1},
          correlation_id: "turn-123",
          causation_id: "cause-456"
        )

      assert_receive {:signal, %Jido.Signal{} = signal}, 1_000

      assert signal.extensions["correlation_id"] == "turn-123"
      assert signal.extensions["causation_id"] == "cause-456"
      assert is_integer(signal.extensions["emitted_at"])
    end
  end
end
