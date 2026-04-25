defmodule RhoFrameworks.ScopeTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.Scope

  describe "from_context/1" do
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

      scope = Scope.from_context(ctx)

      assert scope.organization_id == "org-1"
      assert scope.session_id == "sess-1"
      assert scope.user_id == "user-1"
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

      scope = Scope.from_context(ctx)

      refute Map.has_key?(scope, :tape_module)
      refute Map.has_key?(scope, :tape_name)
      refute Map.has_key?(scope, :depth)
      refute Map.has_key?(scope, :subagent)
      refute Map.has_key?(scope, :prompt_format)
      refute Map.has_key?(scope, :agent_name)
      refute Map.has_key?(scope, :workspace)
    end

    test "handles nil user_id" do
      ctx = %Rho.Context{
        agent_name: :test,
        organization_id: "org-1",
        session_id: "sess-1",
        tape_module: Rho.Tape.Null
      }

      scope = Scope.from_context(ctx)

      assert scope.user_id == nil
    end
  end

  describe "struct" do
    test "enforces organization_id and session_id" do
      assert_raise ArgumentError, fn ->
        struct!(Scope, user_id: "user-1")
      end
    end

    test "creates with required fields" do
      scope = %Scope{organization_id: "org-1", session_id: "sess-1"}
      assert scope.organization_id == "org-1"
      assert scope.session_id == "sess-1"
      assert scope.user_id == nil
    end
  end
end
