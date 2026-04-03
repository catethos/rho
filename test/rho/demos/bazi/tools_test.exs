defmodule Rho.Demos.Bazi.ToolsTest do
  use ExUnit.Case, async: true

  alias Rho.Comms
  alias Rho.Demos.Bazi.Tools

  setup do
    session_id = "test-session-#{System.unique_integer([:positive])}"
    agent_id = "test-agent-#{System.unique_integer([:positive])}"
    role = :advisor_1

    {:ok, session_id: session_id, agent_id: agent_id, role: role}
  end

  describe "submit_chart_data_tool/2" do
    test "returns a tool with correct name", %{session_id: session_id, agent_id: agent_id} do
      tool_def = Tools.submit_chart_data_tool(session_id, agent_id)
      assert tool_def.tool.name == "submit_chart_data"
    end

    test "publishes signal on valid JSON", %{session_id: session_id, agent_id: agent_id} do
      tool_def = Tools.submit_chart_data_tool(session_id, agent_id)
      Comms.subscribe("rho.bazi.#{session_id}.chart.parsed")

      chart_data = Jason.encode!(%{day_master: "甲", pillars: [], notes: "test"})
      assert {:ok, _msg} = tool_def.execute.(%{"chart_data" => chart_data})

      assert_receive {:signal, %Jido.Signal{type: "rho.bazi." <> _, data: data}}, 1000
      assert data.session_id == session_id
      assert data.agent_id == agent_id
      assert is_map(data.chart_data)
      assert data.chart_data["day_master"] == "甲"
    end

    test "returns error on invalid JSON", %{session_id: session_id, agent_id: agent_id} do
      tool_def = Tools.submit_chart_data_tool(session_id, agent_id)
      assert {:error, _msg} = tool_def.execute.(%{"chart_data" => "not json {"})
    end

    test "accepts atom keys", %{session_id: session_id, agent_id: agent_id} do
      tool_def = Tools.submit_chart_data_tool(session_id, agent_id)
      Comms.subscribe("rho.bazi.#{session_id}.chart.parsed")

      chart_data = Jason.encode!(%{day_master: "乙"})
      assert {:ok, _} = tool_def.execute.(%{chart_data: chart_data})

      assert_receive {:signal, %Jido.Signal{data: data}}, 1000
      assert data.chart_data["day_master"] == "乙"
    end
  end

  describe "submit_dimensions_tool/3" do
    test "returns a tool with correct name", %{session_id: session_id, agent_id: agent_id, role: role} do
      tool_def = Tools.submit_dimensions_tool(session_id, agent_id, role)
      assert tool_def.tool.name == "submit_dimensions"
    end

    test "publishes signal on valid JSON list", %{session_id: session_id, agent_id: agent_id, role: role} do
      tool_def = Tools.submit_dimensions_tool(session_id, agent_id, role)
      Comms.subscribe("rho.bazi.#{session_id}.dimensions.proposed")

      dims = Jason.encode!(["财运", "事业", "健康"])
      assert {:ok, _} = tool_def.execute.(%{"dimensions" => dims})

      assert_receive {:signal, %Jido.Signal{type: "rho.bazi." <> _, data: data}}, 1000
      assert data.session_id == session_id
      assert data.agent_id == agent_id
      assert data.role == role
      assert data.dimensions == ["财运", "事业", "健康"]
    end

    test "returns error on non-list JSON", %{session_id: session_id, agent_id: agent_id, role: role} do
      tool_def = Tools.submit_dimensions_tool(session_id, agent_id, role)
      assert {:error, _} = tool_def.execute.(%{"dimensions" => ~s({"key": "value"})})
    end

    test "returns error on invalid JSON", %{session_id: session_id, agent_id: agent_id, role: role} do
      tool_def = Tools.submit_dimensions_tool(session_id, agent_id, role)
      assert {:error, _} = tool_def.execute.(%{"dimensions" => "not json"})
    end
  end

  describe "submit_scores_tool/3" do
    test "returns a tool with correct name", %{session_id: session_id, agent_id: agent_id, role: role} do
      tool_def = Tools.submit_scores_tool(session_id, agent_id, role)
      assert tool_def.tool.name == "submit_scores"
    end

    test "publishes signal on valid JSON map", %{session_id: session_id, agent_id: agent_id, role: role} do
      tool_def = Tools.submit_scores_tool(session_id, agent_id, role)
      Comms.subscribe("rho.bazi.#{session_id}.scores.submitted")

      scores = Jason.encode!(%{"option_a" => %{"财运" => 80, "rationale" => "strong"}, "option_b" => %{"财运" => 60}})
      assert {:ok, _} = tool_def.execute.(%{"round" => 1, "scores" => scores})

      assert_receive {:signal, %Jido.Signal{type: "rho.bazi." <> _, data: data}}, 1000
      assert data.session_id == session_id
      assert data.agent_id == agent_id
      assert data.role == role
      assert data.round == 1
      assert is_map(data.scores)
    end

    test "returns error on non-map JSON", %{session_id: session_id, agent_id: agent_id, role: role} do
      tool_def = Tools.submit_scores_tool(session_id, agent_id, role)
      assert {:error, _} = tool_def.execute.(%{"round" => 1, "scores" => "[1, 2, 3]"})
    end

    test "returns error on invalid JSON", %{session_id: session_id, agent_id: agent_id, role: role} do
      tool_def = Tools.submit_scores_tool(session_id, agent_id, role)
      assert {:error, _} = tool_def.execute.(%{"round" => 1, "scores" => "bad json {"})
    end

    test "accepts atom keys", %{session_id: session_id, agent_id: agent_id, role: role} do
      tool_def = Tools.submit_scores_tool(session_id, agent_id, role)
      Comms.subscribe("rho.bazi.#{session_id}.scores.submitted")

      scores = Jason.encode!(%{"opt" => %{"dim" => 75}})
      assert {:ok, _} = tool_def.execute.(%{round: 2, scores: scores})

      assert_receive {:signal, %Jido.Signal{data: data}}, 1000
      assert data.round == 2
    end
  end

  describe "request_user_info_tool/3" do
    test "returns a tool with correct name", %{session_id: session_id, agent_id: agent_id, role: role} do
      tool_def = Tools.request_user_info_tool(session_id, agent_id, role)
      assert tool_def.tool.name == "request_user_info"
    end

    test "publishes signal with question", %{session_id: session_id, agent_id: agent_id, role: role} do
      tool_def = Tools.request_user_info_tool(session_id, agent_id, role)
      Comms.subscribe("rho.bazi.#{session_id}.user_info.requested")

      assert {:ok, _} = tool_def.execute.(%{"question" => "请问命主的大运是？"})

      assert_receive {:signal, %Jido.Signal{type: "rho.bazi." <> _, data: data}}, 1000
      assert data.session_id == session_id
      assert data.agent_id == agent_id
      assert data.from_advisor == role
      assert data.question == "请问命主的大运是？"
    end

    test "accepts atom keys", %{session_id: session_id, agent_id: agent_id, role: role} do
      tool_def = Tools.request_user_info_tool(session_id, agent_id, role)
      Comms.subscribe("rho.bazi.#{session_id}.user_info.requested")

      assert {:ok, _} = tool_def.execute.(%{question: "五行如何？"})

      assert_receive {:signal, %Jido.Signal{data: data}}, 1000
      assert data.question == "五行如何？"
    end
  end
end
