defmodule Rho.Agent.MailboxTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Rho.Agent.Mailbox
  alias Rho.Agent.Worker

  describe "enqueue and next" do
    test "prefers queued signals over regular submits" do
      state = %Worker{}

      {state, _log} =
        with_log(fn ->
          state
          |> Mailbox.enqueue_submit("hello", [await: :turn], "turn-1")
          |> Mailbox.enqueue_signal(%{kind: :ping})
        end)

      assert {:signal, state, %{kind: :ping}} = Mailbox.next(state)
      assert {:submit, state, "hello", [await: :turn], "turn-1"} = Mailbox.next(state)
      assert {:empty, ^state} = Mailbox.next(state)
    end

    test "keeps the submit turn id with queued content" do
      {state, _log} =
        with_log(fn ->
          %Worker{}
          |> Mailbox.enqueue_submit("first", [], "turn-a")
          |> Mailbox.enqueue_submit("second", [model: "mock"], "turn-b")
        end)

      assert {:submit, state, "first", [], "turn-a"} = Mailbox.next(state)
      assert {:submit, state, "second", [model: "mock"], "turn-b"} = Mailbox.next(state)
      assert {:empty, ^state} = Mailbox.next(state)
    end
  end
end
