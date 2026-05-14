defmodule Rho.Tape.ServiceTest do
  use ExUnit.Case

  alias Rho.Tape.{Service, Store}

  @test_tape "test_service_#{System.os_time(:nanosecond)}"

  setup do
    on_exit(fn -> Store.clear(@test_tape) end)
    :ok
  end

  describe "session_tape/2" do
    test "returns deterministic tape name" do
      name1 = Service.session_tape("session1", "/workspace")
      name2 = Service.session_tape("session1", "/workspace")
      name3 = Service.session_tape("session2", "/workspace")

      assert name1 == name2
      assert name1 != name3
      assert String.starts_with?(name1, "session_")
    end
  end

  describe "ensure_bootstrap_anchor/1" do
    test "creates initial anchor if none exists" do
      Service.ensure_bootstrap_anchor(@test_tape)

      anchor = Store.last_anchor(@test_tape)
      assert anchor != nil
      assert anchor.kind == :anchor
      assert anchor.payload["name"] == "session/start"
      assert anchor.payload["state"]["phase"] == "start"
    end

    test "does not create duplicate anchor" do
      Service.ensure_bootstrap_anchor(@test_tape)
      Service.ensure_bootstrap_anchor(@test_tape)

      entries = Store.read(@test_tape)
      anchors = Enum.filter(entries, &(&1.kind == :anchor))
      assert match?([_], anchors)
    end
  end

  describe "append/4" do
    test "appends entry to tape" do
      {:ok, entry} = Service.append(@test_tape, :message, %{"role" => "user", "content" => "hi"})

      assert entry.kind == :message
      assert entry.id != nil
    end
  end

  describe "append_from_event/2" do
    test "records llm_text as assistant message" do
      Service.append_from_event(@test_tape, %{type: :llm_text, text: "hello"})

      [entry] = Store.read(@test_tape)
      assert entry.kind == :message
      assert entry.payload["role"] == "assistant"
      assert entry.payload["content"] == "hello"
    end

    test "records tool_start as tool_call" do
      Service.append_from_event(@test_tape, %{
        type: :tool_start,
        name: "bash",
        args: %{"cmd" => "ls"},
        call_id: "call_123"
      })

      [entry] = Store.read(@test_tape)
      assert entry.kind == :tool_call
      assert entry.payload["name"] == "bash"
      assert entry.payload["call_id"] == "call_123"
    end

    test "records tool_result" do
      Service.append_from_event(@test_tape, %{
        type: :tool_result,
        name: "bash",
        status: :ok,
        output: "file.txt",
        call_id: "call_123"
      })

      [entry] = Store.read(@test_tape)
      assert entry.kind == :tool_result
      assert entry.payload["status"] == "ok"
      assert entry.payload["call_id"] == "call_123"
    end

    test "ignores step_start events" do
      Service.append_from_event(@test_tape, %{type: :step_start, step: 1, max_steps: 50})
      assert Store.read(@test_tape) == []
    end
  end

  describe "info/1" do
    test "returns tape statistics" do
      Service.ensure_bootstrap_anchor(@test_tape)
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "hi"})
      Service.append(@test_tape, :message, %{"role" => "assistant", "content" => "hello"})

      info = Service.info(@test_tape)
      assert info.entry_count == 3
      assert info.anchor_count == 1
      assert info.last_anchor_name == "session/start"
      assert info.entries_since_anchor == 2
    end
  end

  describe "search/3" do
    test "finds messages containing query" do
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "hello world"})
      Service.append(@test_tape, :message, %{"role" => "assistant", "content" => "hi there"})
      Service.append(@test_tape, :event, %{"name" => "hello_event"})

      results = Service.search(@test_tape, "hello")
      assert match?([_, _], results)
      assert hd(results).payload["content"] == "hello world"
    end

    test "case-insensitive search" do
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "Hello World"})

      results = Service.search(@test_tape, "hello")
      assert match?([_], results)
    end
  end

  describe "reset/2" do
    test "clears tape and re-bootstraps" do
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "hi"})
      Service.reset(@test_tape)

      entries = Store.read(@test_tape)
      assert match?([_], entries)
      assert hd(entries).kind == :anchor
    end
  end
end
