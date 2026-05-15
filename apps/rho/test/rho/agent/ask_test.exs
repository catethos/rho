defmodule Rho.Agent.AskTest do
  use ExUnit.Case, async: true

  alias Rho.Agent.Ask

  describe "ask/5" do
    test "waits on the session event bus for the submitted turn result" do
      parent = self()
      session_id = "ask_session_#{System.unique_integer([:positive])}"
      turn_id = "turn_#{System.unique_integer([:positive])}"

      worker =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      info_fun = fn ^worker -> %{session_id: session_id} end

      submit_fun = fn ^worker, "hello", _opts ->
        send(parent, :submitted)

        Task.start(fn ->
          Process.sleep(10)

          send(
            parent,
            Rho.Events.event(:turn_finished, session_id, "agent", %{
              turn_id: turn_id,
              result: {:ok, "answer"}
            })
          )
        end)

        {:ok, turn_id}
      end

      assert Ask.ask(worker, "hello", [], info_fun, submit_fun) == {:ok, "answer"}
      assert_received :submitted
      send(worker, :stop)
    end

    test "unwraps final tool results in turn mode" do
      turn_id = "turn_final_#{System.unique_integer([:positive])}"

      send(
        self(),
        Rho.Events.event(:turn_finished, "sid", "agent", %{
          turn_id: turn_id,
          result: {:final, %{done: true}}
        })
      )

      assert Ask.await_reply(turn_id, :turn) == {:ok, %{done: true}}
    end

    test "finish mode waits through ordinary turn results until final" do
      send(self(), Rho.Events.event(:turn_finished, "sid", "agent", %{result: {:ok, "partial"}}))
      send(self(), Rho.Events.event(:turn_finished, "sid", "agent", %{result: {:final, "done"}}))

      assert Ask.await_reply("ignored", :finish) == {:ok, "done"}
    end
  end
end
