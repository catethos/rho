defmodule Rho.Tape.StoreTest do
  use ExUnit.Case

  alias Rho.Tape.{Entry, Store}

  @test_tape "test_store_#{System.os_time(:nanosecond)}"

  setup do
    on_exit(fn -> Store.clear(@test_tape) end)
    :ok
  end

  describe "append/2" do
    test "assigns monotonic IDs" do
      e1 = Entry.new(:message, %{"role" => "user", "content" => "hi"})
      e2 = Entry.new(:message, %{"role" => "assistant", "content" => "hello"})

      {:ok, stored1} = Store.append(@test_tape, e1)
      {:ok, stored2} = Store.append(@test_tape, e2)

      assert stored1.id == 1
      assert stored2.id == 2
    end
  end

  describe "read/1" do
    test "returns entries sorted by ID" do
      Store.append(@test_tape, Entry.new(:message, %{"role" => "user", "content" => "a"}))
      Store.append(@test_tape, Entry.new(:message, %{"role" => "assistant", "content" => "b"}))
      Store.append(@test_tape, Entry.new(:event, %{"name" => "test"}))

      entries = Store.read(@test_tape)
      assert match?([_, _, _], entries)
      assert Enum.map(entries, & &1.id) == [1, 2, 3]
    end

    test "returns empty list for nonexistent tape" do
      assert Store.read("nonexistent_tape_xyz") == []
    end
  end

  describe "read/2" do
    test "filters entries with id >= from_id" do
      Store.append(@test_tape, Entry.new(:message, %{"content" => "a"}))
      Store.append(@test_tape, Entry.new(:message, %{"content" => "b"}))
      Store.append(@test_tape, Entry.new(:message, %{"content" => "c"}))

      entries = Store.read(@test_tape, 2)
      assert match?([_, _], entries)
      assert Enum.map(entries, & &1.id) == [2, 3]
    end
  end

  describe "clear/1" do
    test "removes all entries" do
      Store.append(@test_tape, Entry.new(:message, %{"content" => "test"}))
      assert length(Store.read(@test_tape)) == 1

      Store.clear(@test_tape)
      assert Store.read(@test_tape) == []
    end
  end

  describe "last_anchor/1" do
    test "returns nil when no anchors exist" do
      Store.append(@test_tape, Entry.new(:message, %{"content" => "test"}))
      assert Store.last_anchor(@test_tape) == nil
    end

    test "returns the latest anchor" do
      Store.append(@test_tape, Entry.new(:anchor, %{"name" => "first"}))
      Store.append(@test_tape, Entry.new(:message, %{"content" => "test"}))
      Store.append(@test_tape, Entry.new(:anchor, %{"name" => "second"}))

      anchor = Store.last_anchor(@test_tape)
      assert anchor.kind == :anchor
      assert anchor.payload["name"] == "second"
      assert anchor.id == 3
    end
  end
end
