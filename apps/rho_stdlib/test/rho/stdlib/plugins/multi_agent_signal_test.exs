defmodule Rho.Stdlib.Plugins.MultiAgentSignalTest do
  @moduledoc """
  Characterisation tests for `Rho.Stdlib.Plugins.MultiAgent.handle_signal/3`.

  These tests pin the contract that `process_signal/2` in `Rho.Agent.Worker`
  used to enforce inline. After Phase 3 of the kernel-minimisation plan,
  the plugin owns the signal-type strings and their dispatch.
  """

  use ExUnit.Case, async: false

  alias Rho.Agent.Registry, as: AgentRegistry
  alias Rho.Stdlib.Plugins.MultiAgent

  setup do
    AgentRegistry.init_table()
    :ok
  end

  defp ctx do
    %{
      tape_name: "tape",
      workspace: "/tmp",
      agent_name: :default,
      agent_id: "agent_1",
      session_id: "sess_1",
      depth: 0
    }
  end

  describe "rho.task.requested" do
    test "returns {:start_turn, task, opts} with task_id, delegated, max_steps" do
      signal = %{
        type: "rho.task.requested",
        data: %{task: "do the thing", task_id: "task_1", max_steps: 7}
      }

      assert {:start_turn, "do the thing", opts} = MultiAgent.handle_signal(signal, [], ctx())
      assert opts[:task_id] == "task_1"
      assert opts[:delegated] == true
      assert opts[:max_steps] == 7
    end

    test "tolerates string-keyed payload" do
      signal = %{
        type: "rho.task.requested",
        data: %{"task" => "from json", "task_id" => "task_2"}
      }

      assert {:start_turn, "from json", opts} = MultiAgent.handle_signal(signal, [], ctx())
      assert opts[:task_id] == "task_2"
    end

    test "defaults max_steps when missing" do
      signal = %{type: "rho.task.requested", data: %{task: "x"}}
      assert {:start_turn, "x", opts} = MultiAgent.handle_signal(signal, [], ctx())
      assert is_integer(opts[:max_steps])
      assert opts[:max_steps] > 0
    end

    test "returns :ignore when task is missing" do
      signal = %{type: "rho.task.requested", data: %{task_id: "x"}}
      assert MultiAgent.handle_signal(signal, [], ctx()) == :ignore
    end
  end

  describe "rho.message.sent" do
    test "external message produces external-prefixed content" do
      signal = %{
        type: "rho.message.sent",
        data: %{message: "hello from outside", from: "external"}
      }

      assert {:start_turn, content, _opts} = MultiAgent.handle_signal(signal, [], ctx())
      assert content =~ "[External message]"
      assert content =~ "hello from outside"
    end

    test "known sender produces inter-agent header with role" do
      AgentRegistry.register("sender_agent", %{
        session_id: "sess_1",
        role: :researcher,
        capabilities: [],
        pid: self(),
        status: :idle
      })

      signal = %{
        type: "rho.message.sent",
        data: %{message: "ping", from: "sender_agent"}
      }

      assert {:start_turn, content, _opts} = MultiAgent.handle_signal(signal, [], ctx())
      assert content =~ "[Inter-agent message from researcher (sender_agent)]"
      assert content =~ "ping"
      assert content =~ "send_message"
      assert content =~ "sender_agent"
    end

    test "unknown sender falls back to :unknown role" do
      signal = %{
        type: "rho.message.sent",
        data: %{message: "lost soul", from: "ghost_agent"}
      }

      assert {:start_turn, content, _opts} = MultiAgent.handle_signal(signal, [], ctx())
      assert content =~ "[Inter-agent message from unknown (ghost_agent)]"
      assert content =~ "lost soul"
    end

    test "non-binary `from` returns the bare message" do
      signal = %{
        type: "rho.message.sent",
        data: %{message: "bare", from: nil}
      }

      assert {:start_turn, "bare", _opts} = MultiAgent.handle_signal(signal, [], ctx())
    end

    test "returns :ignore when message is missing" do
      signal = %{type: "rho.message.sent", data: %{from: "external"}}
      assert MultiAgent.handle_signal(signal, [], ctx()) == :ignore
    end

    test "tolerates string-keyed payload" do
      signal = %{
        type: "rho.message.sent",
        data: %{"message" => "json hi", "from" => "external"}
      }

      assert {:start_turn, content, _opts} = MultiAgent.handle_signal(signal, [], ctx())
      assert content =~ "json hi"
    end
  end

  describe "unknown signals" do
    test "returns :ignore" do
      assert MultiAgent.handle_signal(%{type: "totally.unknown"}, [], ctx()) == :ignore
    end

    test "returns :ignore for non-map signals" do
      assert MultiAgent.handle_signal(:not_a_signal, [], ctx()) == :ignore
    end
  end
end
