defmodule Rho.Tape.HandoffTest do
  use ExUnit.Case

  alias Rho.Tape.{Service, Store, View}

  @test_tape "test_handoff_#{System.os_time(:nanosecond)}"

  setup do
    on_exit(fn -> Store.clear(@test_tape) end)
    :ok
  end

  describe "handoff/4" do
    test "creates anchor with full state contract" do
      Service.ensure_bootstrap_anchor(@test_tape)
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "find the bug"})
      Service.append(@test_tape, :message, %{"role" => "assistant", "content" => "found it"})

      {:ok, anchor} =
        Service.handoff(@test_tape, "implement", "Discovery complete. Bug found in auth module.",
          next_steps: ["Fix auth module", "Run tests"]
        )

      assert anchor.kind == :anchor
      assert anchor.payload["name"] == "implement"
      assert anchor.payload["state"]["phase"] == "implement"
      assert anchor.payload["state"]["summary"] == "Discovery complete. Bug found in auth module."
      assert anchor.payload["state"]["next_steps"] == ["Fix auth module", "Run tests"]
      assert anchor.payload["state"]["owner"] == "agent"
      assert is_list(anchor.payload["state"]["source_ids"])
      assert length(anchor.payload["state"]["source_ids"]) > 0
    end

    test "shifts default view to start after new anchor" do
      Service.ensure_bootstrap_anchor(@test_tape)
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "old message"})
      Service.handoff(@test_tape, "implement", "Phase 1 done.")
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "new message"})

      view = View.default(@test_tape)
      assert length(view.entries) == 1
      assert hd(view.entries).payload["content"] == "new message"
    end

    test "preserves entries before handoff on tape" do
      Service.ensure_bootstrap_anchor(@test_tape)
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "old"})
      Service.handoff(@test_tape, "implement", "Done.")
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "new"})

      all_entries = Store.read(@test_tape)
      messages = Enum.filter(all_entries, &(&1.kind == :message))
      assert length(messages) == 2
    end

    test "auto-collects source_ids from recent entries" do
      Service.ensure_bootstrap_anchor(@test_tape)

      ids =
        for i <- 1..5 do
          {:ok, e} =
            Service.append(@test_tape, :message, %{"role" => "user", "content" => "msg #{i}"})

          e.id
        end

      {:ok, anchor} = Service.handoff(@test_tape, "next", "Summary.")
      assert anchor.payload["state"]["source_ids"] == ids
    end

    test "accepts custom source_ids" do
      Service.ensure_bootstrap_anchor(@test_tape)
      {:ok, anchor} = Service.handoff(@test_tape, "next", "Summary.", source_ids: [10, 20, 30])
      assert anchor.payload["state"]["source_ids"] == [10, 20, 30]
    end

    test "accepts owner option" do
      {:ok, anchor} = Service.handoff(@test_tape, "compact", "Auto summary.", owner: "system")
      assert anchor.payload["state"]["owner"] == "system"
    end
  end
end
