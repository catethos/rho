defmodule RhoFrameworks.Tools.WorkflowToolsTest do
  @moduledoc """
  Unit tests for the WorkflowTools module — focused on Phase 8 additions:
  the `clarify` tool's broadcast behaviour and the `tool_for_use_case/1`
  accessor that the wizard's per-step chat uses to pick the right tool.

  The wrappers around UseCase modules (load_similar_roles, …) are
  already exercised by `NamedTableRoundtripTest` and the per-UseCase
  test files; we don't repeat them here.
  """

  use ExUnit.Case, async: false

  alias Rho.Events.Event, as: LiveEvent

  alias RhoFrameworks.Tools.WorkflowTools

  alias RhoFrameworks.UseCases.{
    GenerateFrameworkSkeletons,
    GenerateProficiency,
    LoadSimilarRoles,
    PickTemplate,
    ResearchDomain,
    SaveFramework
  }

  describe "tool_for_use_case/1" do
    test "returns the tool def for chat-eligible UseCases" do
      assert %{tool: %{name: "load_similar_roles"}, execute: _} =
               WorkflowTools.tool_for_use_case(LoadSimilarRoles)

      assert %{tool: %{name: "generate_framework_skeletons"}} =
               WorkflowTools.tool_for_use_case(GenerateFrameworkSkeletons)

      assert %{tool: %{name: "generate_proficiency"}} =
               WorkflowTools.tool_for_use_case(GenerateProficiency)

      assert %{tool: %{name: "save_framework"}} =
               WorkflowTools.tool_for_use_case(SaveFramework)
    end

    test "returns nil for UseCases with no chat surface" do
      assert WorkflowTools.tool_for_use_case(PickTemplate) == nil
      assert WorkflowTools.tool_for_use_case(ResearchDomain) == nil
    end
  end

  describe "clarify_tool/0" do
    test "is included in the tool list with the expected schema" do
      tool_def = WorkflowTools.clarify_tool()

      assert %{tool: %{name: "clarify"}, execute: _} = tool_def

      param_names =
        tool_def.tool.parameter_schema
        |> Enum.map(fn {name, _} -> name end)
        |> Enum.sort()

      assert param_names == [:question]
    end

    test "execute broadcasts :step_chat_clarify on the session topic and ends the turn" do
      session_id = "sess-clarify-#{System.unique_integer([:positive])}"
      agent_id = "agent-step-chat-#{System.unique_integer([:positive])}"

      :ok = Rho.Events.subscribe(session_id)
      on_exit(fn -> Rho.Events.unsubscribe(session_id) end)

      ctx = %Rho.Context{
        agent_name: :step_chat,
        session_id: session_id,
        agent_id: agent_id,
        tape_module: Rho.Tape.Null
      }

      tool_def = WorkflowTools.clarify_tool()
      result = tool_def.execute.(%{question: "Should I use 8 skills or 12?"}, ctx)

      # `{:final, _}` ends the turn cleanly (see Rho.Tool result types).
      assert {:final, "Should I use 8 skills or 12?"} = result

      assert_receive %LiveEvent{
                       kind: :step_chat_clarify,
                       session_id: ^session_id,
                       agent_id: ^agent_id,
                       data: %{
                         question: "Should I use 8 skills or 12?",
                         agent_id: ^agent_id
                       }
                     },
                     500
    end

    test "execute does not broadcast when session_id is nil" do
      :ok = Rho.Events.subscribe("unrelated-topic")
      on_exit(fn -> Rho.Events.unsubscribe("unrelated-topic") end)

      ctx = %Rho.Context{
        agent_name: :step_chat,
        session_id: nil,
        agent_id: "a-1",
        tape_module: Rho.Tape.Null
      }

      tool_def = WorkflowTools.clarify_tool()
      assert {:final, "ambiguous"} = tool_def.execute.(%{question: "ambiguous"}, ctx)

      refute_receive %LiveEvent{kind: :step_chat_clarify}, 50
    end
  end
end
