defmodule Rho.Tape.CompactTest do
  use ExUnit.Case

  alias Rho.Tape.{Compact, Service, Store}

  @test_tape "test_compact_#{System.os_time(:nanosecond)}"

  setup do
    on_exit(fn -> Store.clear(@test_tape) end)
    :ok
  end

  describe "estimate_tokens/1" do
    test "estimates based on content length" do
      Service.ensure_bootstrap_anchor(@test_tape)
      # 400 chars ~= 100 tokens
      Service.append(@test_tape, :message, %{
        "role" => "user",
        "content" => String.duplicate("a", 400)
      })

      tokens = Compact.estimate_tokens(@test_tape)
      assert tokens == 100
    end

    test "returns 0 for empty tape" do
      Service.ensure_bootstrap_anchor(@test_tape)
      assert Compact.estimate_tokens(@test_tape) == 0
    end
  end

  describe "needed?/2" do
    test "returns false when under threshold" do
      Service.ensure_bootstrap_anchor(@test_tape)
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "short"})

      refute Compact.needed?(@test_tape)
    end

    test "returns true when over threshold" do
      Service.ensure_bootstrap_anchor(@test_tape)
      # 800_000 chars ~= 200_000 tokens, well over default 100k threshold
      Service.append(@test_tape, :message, %{
        "role" => "user",
        "content" => String.duplicate("x", 800_000)
      })

      assert Compact.needed?(@test_tape)
    end

    test "respects custom threshold" do
      Service.ensure_bootstrap_anchor(@test_tape)

      Service.append(@test_tape, :message, %{
        "role" => "user",
        "content" => String.duplicate("x", 400)
      })

      assert Compact.needed?(@test_tape, threshold: 50)
      refute Compact.needed?(@test_tape, threshold: 200)
    end
  end

  describe "run_if_needed/2" do
    test "returns :not_needed when under threshold" do
      Service.ensure_bootstrap_anchor(@test_tape)
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "short"})

      assert {:ok, :not_needed} = Compact.run_if_needed(@test_tape, model: "test")
    end
  end

  describe "run/2" do
    test "returns :no_entries for empty view" do
      Service.ensure_bootstrap_anchor(@test_tape)
      assert {:ok, :no_entries} = Compact.run(@test_tape, model: "test")
    end

    test "raises without model option" do
      assert_raise RuntimeError, ~r/requires :model/, fn ->
        Compact.run(@test_tape)
      end
    end
  end
end
