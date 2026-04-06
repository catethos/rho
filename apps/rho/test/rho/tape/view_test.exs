defmodule Rho.Tape.ViewTest do
  use ExUnit.Case

  alias Rho.Tape.{Service, Store, View}

  @test_tape "test_view_#{System.os_time(:nanosecond)}"

  setup do
    on_exit(fn ->
      Store.clear(@test_tape)
      View.invalidate_cache(@test_tape)
    end)

    # Ensure clean state before each test
    Store.clear(@test_tape)
    View.invalidate_cache(@test_tape)
    :ok
  end

  describe "default/1" do
    test "returns entries after latest anchor" do
      Service.ensure_bootstrap_anchor(@test_tape)
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "hello"})
      Service.append(@test_tape, :message, %{"role" => "assistant", "content" => "hi"})

      view = View.default(@test_tape)
      assert view.policy == :default
      assert view.anchor_id != nil
      assert length(view.entries) == 2
    end

    test "filters out non-conversational entries" do
      Service.ensure_bootstrap_anchor(@test_tape)
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "hello"})
      Service.append(@test_tape, :event, %{"name" => "usage"})
      Service.append(@test_tape, :message, %{"role" => "assistant", "content" => "hi"})

      view = View.default(@test_tape)
      assert length(view.entries) == 2
      assert Enum.all?(view.entries, &(&1.kind in [:message, :tool_call, :tool_result]))
    end

    test "includes all entries when no anchor exists" do
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "hello"})

      view = View.default(@test_tape)
      assert view.anchor_id == nil
      assert length(view.entries) == 1
    end
  end

  describe "to_messages/1" do
    test "converts user and assistant messages" do
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "hello"})
      Service.append(@test_tape, :message, %{"role" => "assistant", "content" => "hi there"})

      view = View.default(@test_tape)
      msgs = View.to_messages(view)

      assert length(msgs) == 2
      assert %{role: :user} = Enum.at(msgs, 0)
      assert %{role: :assistant} = Enum.at(msgs, 1)
    end

    test "prepends anchor summary as user context message" do
      Service.ensure_bootstrap_anchor(@test_tape)
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "hello"})

      view = View.default(@test_tape)
      msgs = View.to_messages(view)

      # First message should be the anchor context
      assert %{role: :user} = hd(msgs)
    end

    test "drops orphaned tool_results without matching tool_call" do
      # Simulate post-anchor state where tool_call was before the anchor
      # but tool_result is after — only the result is in the view.
      Service.append(@test_tape, :message, %{"role" => "user", "content" => "hello"})

      Service.append(@test_tape, :tool_result, %{
        "name" => "bash",
        "output" => "file.txt",
        "call_id" => "orphaned_call_id",
        "status" => "ok"
      })

      view = View.default(@test_tape)
      msgs = View.to_messages(view)

      # The orphaned tool_result should be stripped; only the user message remains
      assert length(msgs) == 1
      assert %{role: :user} = hd(msgs)
    end

    test "handles tool call and result pairs" do
      Service.append(@test_tape, :tool_call, %{
        "name" => "bash",
        "args" => %{"cmd" => "ls"},
        "call_id" => "call_abc"
      })

      Service.append(@test_tape, :tool_result, %{
        "name" => "bash",
        "output" => "file.txt",
        "call_id" => "call_abc",
        "status" => "ok"
      })

      view = View.default(@test_tape)
      msgs = View.to_messages(view)

      assert length(msgs) == 2
      # First should be assistant message with tool_calls
      assert %{role: :assistant} = Enum.at(msgs, 0)
      # Second should be tool result
      assert %{role: :tool} = Enum.at(msgs, 1)
    end
  end
end
