defmodule RhoWeb.AppLiveAgentEventsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.AppLive.AgentEvents
  alias RhoWeb.Session.SessionCore

  test "parent_agent_id/2 derives the primary parent when none is supplied" do
    sid = "chat_test_agent_events"

    assert AgentEvents.parent_agent_id(sid, %{}) == Rho.Agent.Primary.agent_id(sid)
    assert AgentEvents.parent_agent_id(sid, %{"parent_id" => ""}) == sid
    assert AgentEvents.parent_agent_id(sid, %{"parent_id" => "agent-123"}) == "agent-123"
  end

  test "role_atom/1 preserves known roles and falls back for unknown strings" do
    assert AgentEvents.role_atom("default") == :default
    assert AgentEvents.role_atom(:data_table) == :data_table
    assert AgentEvents.role_atom("not_a_loaded_agent_role") == :worker
    assert AgentEvents.role_atom(nil) == :worker
  end

  test "agent_entry/3 builds the tab state used by AppLive" do
    entry = AgentEvents.agent_entry("agent-1", "session-1", :default)

    assert entry.agent_id == "agent-1"
    assert entry.session_id == "session-1"
    assert entry.role == :default
    assert entry.status == :idle
    assert entry.depth == 0
    assert entry.capabilities == []
    assert entry.model == nil
    assert entry.step == nil
    assert entry.max_steps == nil
  end

  test "remove_agent_state/3 drops the removed tab and restores primary active tab" do
    sid = "chat_remove_agent"
    primary = SessionCore.primary_agent_id(sid)
    secondary = "#{primary}/child"

    assigns = %{
      agent_tab_order: [primary, secondary],
      agents: %{primary => %{role: :default}, secondary => %{role: :worker}},
      active_agent_id: secondary
    }

    assert {[^primary], %{^primary => %{role: :default}}, ^primary} =
             AgentEvents.remove_agent_state(assigns, secondary, primary)
  end

  test "remove_agent_state/3 preserves active tab when another tab is removed" do
    sid = "chat_remove_inactive_agent"
    primary = SessionCore.primary_agent_id(sid)
    secondary = "#{primary}/child"

    assigns = %{
      agent_tab_order: [primary, secondary],
      agents: %{primary => %{role: :default}, secondary => %{role: :worker}},
      active_agent_id: primary
    }

    assert {[^primary], %{^primary => %{role: :default}}, ^primary} =
             AgentEvents.remove_agent_state(assigns, secondary, primary)
  end
end
