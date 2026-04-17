defmodule RhoFrameworks.RuntimeTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.Runtime

  describe "from_rho_context/1" do
    test "extracts relevant fields from Rho.Context" do
      ctx = %Rho.Context{
        agent_name: :test,
        organization_id: "org-1",
        session_id: "sess-1",
        user_id: "user-1",
        agent_id: "agent-1",
        tape_module: Rho.Tape.Null,
        tape_name: "tape-1",
        depth: 2,
        subagent: true,
        prompt_format: :xml,
        workspace: "/tmp"
      }

      rt = Runtime.from_rho_context(ctx)

      assert rt.mode == :agent
      assert rt.organization_id == "org-1"
      assert rt.session_id == "sess-1"
      assert rt.user_id == "user-1"
      assert rt.execution_id == "agent-1"
      assert rt.parent_agent_id == "agent-1"
      assert rt.metadata == %{}
    end

    test "agent infra fields are not present" do
      ctx = %Rho.Context{
        agent_name: :test,
        organization_id: "org-1",
        session_id: "sess-1",
        tape_module: Rho.Tape.Null,
        depth: 3,
        subagent: true,
        prompt_format: :xml
      }

      rt = Runtime.from_rho_context(ctx)

      refute Map.has_key?(rt, :tape_module)
      refute Map.has_key?(rt, :tape_name)
      refute Map.has_key?(rt, :depth)
      refute Map.has_key?(rt, :subagent)
      refute Map.has_key?(rt, :prompt_format)
      refute Map.has_key?(rt, :agent_name)
      refute Map.has_key?(rt, :workspace)
    end
  end

  describe "new_flow/1" do
    test "creates a flow-mode Runtime" do
      rt =
        Runtime.new_flow(
          organization_id: "org-1",
          session_id: "sess-flow",
          execution_id: "flow-run-1"
        )

      assert rt.mode == :flow
      assert rt.organization_id == "org-1"
      assert rt.session_id == "sess-flow"
      assert rt.execution_id == "flow-run-1"
      assert rt.parent_agent_id == nil
      assert rt.metadata == %{}
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, fn ->
        Runtime.new_flow(mode: :flow)
      end
    end
  end

  describe "lite_parent_id/1" do
    test "returns parent_agent_id in agent mode" do
      rt = %Runtime{
        mode: :agent,
        organization_id: "org-1",
        session_id: "sess-1",
        parent_agent_id: "agent-42"
      }

      assert Runtime.lite_parent_id(rt) == "agent-42"
    end

    test "returns flow:<execution_id> in flow mode" do
      rt = %Runtime{
        mode: :flow,
        organization_id: "org-1",
        session_id: "sess-1",
        execution_id: "flow-run-7"
      }

      assert Runtime.lite_parent_id(rt) == "flow:flow-run-7"
    end
  end
end
