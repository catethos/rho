defmodule Rho.Tape.EntryTest do
  use ExUnit.Case, async: true

  alias Rho.Tape.Entry

  describe "new/3" do
    test "creates entry with nil id and ISO 8601 date" do
      entry = Entry.new(:message, %{role: "user", content: "hello"})

      assert entry.id == nil
      assert entry.kind == :message
      assert entry.payload == %{"role" => "user", "content" => "hello"}
      assert entry.meta == %{}
      assert is_binary(entry.date)
    end

    test "normalizes atom keys to strings" do
      entry = Entry.new(:event, %{name: "test", nested: %{key: "val"}})

      assert entry.payload == %{"name" => "test", "nested" => %{"key" => "val"}}
    end

    test "preserves string keys" do
      entry = Entry.new(:message, %{"role" => "user", "content" => "hi"})

      assert entry.payload == %{"role" => "user", "content" => "hi"}
    end

    test "normalizes meta keys" do
      entry = Entry.new(:event, %{}, %{source: "test"})

      assert entry.meta == %{"source" => "test"}
    end
  end

  describe "to_json/1 and from_json/1" do
    test "round-trips correctly" do
      entry = Entry.new(:message, %{"role" => "assistant", "content" => "hi"})
      entry = %{entry | id: 42}

      json = Entry.to_json(entry)
      assert {:ok, decoded} = Entry.from_json(json)

      assert decoded.id == 42
      assert decoded.kind == :message
      assert decoded.payload == %{"role" => "assistant", "content" => "hi"}
      assert decoded.date == entry.date
    end

    test "redacts base64 data URIs" do
      content = "image: data:image/png;base64,iVBORw0KGgoAAAANSUhEUg== end"
      entry = Entry.new(:message, %{"content" => content})
      entry = %{entry | id: 1}

      json = Entry.to_json(entry)
      refute String.contains?(json, "iVBORw0KGgo")
      assert String.contains?(json, "[media]")
    end
  end

  describe "normalize_keys/1" do
    test "handles lists" do
      assert Entry.normalize_keys([%{a: 1}, %{b: 2}]) == [%{"a" => 1}, %{"b" => 2}]
    end

    test "handles non-map values" do
      assert Entry.normalize_keys("hello") == "hello"
      assert Entry.normalize_keys(42) == 42
    end
  end
end
