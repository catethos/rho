defmodule Rho.Demos.Bazi.Tools do
  @moduledoc """
  Bazi-specific tools for advisor agents.
  """

  alias Rho.Comms

  @doc """
  Builds the submit_chart_data tool for the given session and agent.

  The tool receives JSON-encoded chart data extracted from a bazi chart image
  and publishes it to the signal bus.
  """
  def submit_chart_data_tool(session_id, agent_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "submit_chart_data",
          description:
            "提交从八字命盘图片中提取的结构化数据。请以JSON格式提交四柱、天干、地支、藏干、十神等信息。",
          parameter_schema: [
            chart_data: [
              type: :string,
              required: true,
              doc: "JSON object containing day_master, pillars, notes, and other chart fields."
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        raw = args["chart_data"] || args[:chart_data]

        case Jason.decode(raw) do
          {:ok, chart_data} ->
            Comms.publish(
              "rho.bazi.#{session_id}.chart.parsed",
              %{
                session_id: session_id,
                agent_id: agent_id,
                chart_data: chart_data
              },
              source: "/session/#{session_id}/agent/#{agent_id}"
            )

            {:ok, "Chart data submitted successfully."}

          _ ->
            {:error, "Invalid chart_data format. Must be a valid JSON object."}
        end
      end
    }
  end

  @doc """
  Builds the submit_dimensions tool for the given session, agent, and role.

  The tool receives a JSON array of dimension names proposed by the advisor.
  """
  def submit_dimensions_tool(session_id, agent_id, role) do
    %{
      tool:
        ReqLLM.tool(
          name: "submit_dimensions",
          description:
            "提交你建议的3-5个评分维度。参数必须是JSON数组格式，例如: [\"财运\", \"事业发展\", \"健康\"]",
          parameter_schema: [
            dimensions: [
              type: :string,
              required: true,
              doc: ~s|必须是JSON数组格式。例如: ["事业发展", "财运", "五行契合", "时机", "风险"]。不要用其他格式。|
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        raw = args["dimensions"] || args[:dimensions]

        # Handle: already a list (framework decoded) or JSON string
        dims = cond do
          is_list(raw) -> Enum.map(raw, &to_string/1)
          is_binary(raw) ->
            case Jason.decode(raw) do
              {:ok, d} when is_list(d) -> d
              _ -> nil
            end
          true -> nil
        end

        if is_list(dims) and dims != [] do
          Comms.publish(
            "rho.bazi.#{session_id}.dimensions.proposed",
            %{
              session_id: session_id,
              agent_id: agent_id,
              role: role,
              dimensions: dims
            },
            source: "/session/#{session_id}/agent/#{agent_id}"
          )

          {:ok, "Dimensions submitted: #{Enum.join(dims, ", ")}."}
        else
          {:error, "No dimensions found. Please provide a JSON array like [\"财运\", \"事业\"]."}
        end
      end
    }
  end

  @doc """
  Builds the submit_scores tool for the given session, agent, and role.

  The tool receives a round number and a JSON object of scores grouped by option.
  """
  def submit_scores_tool(session_id, agent_id, role) do
    %{
      tool:
        ReqLLM.tool(
          name: "submit_scores",
          description:
            "提交对每个选项在各维度上的评分。每个维度0-100分，并附上理由。注意：选项名称必须使用用户提供的原文（如\"Stay at Pulsifi\"），不要用option_a等替代。",
          parameter_schema: [
            round: [type: :integer, required: true, doc: "当前轮次（1或2）"],
            scores: [
              type: :string,
              required: true,
              doc:
                ~s|JSON对象，以用户原始选项名称为key。例如: {"Stay at Pulsifi": {"事业发展": 80, "财运": 70, "rationale": "分析理由..."}, "Find new job": {"事业发展": 75, ...}}。必须使用用户提供的选项原文作为key。|
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        round = args["round"] || args[:round]
        raw_scores = args["scores"] || args[:scores]

        # Handle: already a map, or JSON string
        scores = cond do
          is_map(raw_scores) -> raw_scores
          is_binary(raw_scores) ->
            case Jason.decode(raw_scores) do
              {:ok, s} when is_map(s) -> s
              _ -> nil
            end
          true -> nil
        end

        if scores do
            Comms.publish(
              "rho.bazi.#{session_id}.scores.submitted",
              %{
                session_id: session_id,
                agent_id: agent_id,
                role: role,
                round: round,
                scores: scores
              },
              source: "/session/#{session_id}/agent/#{agent_id}"
            )

            {:ok, "第#{round}轮评分已提交。"}
        else
            {:error, "评分格式无效。请提交JSON对象，按选项分组。"}
        end
      end
    }
  end

  @doc """
  Builds the request_user_info tool for the given session, agent, and role.

  The tool publishes a question to the signal bus for the Chairman to relay to the user.
  """
  def request_user_info_tool(session_id, agent_id, role) do
    %{
      tool:
        ReqLLM.tool(
          name: "request_user_info",
          description:
            "向用户请求补充信息（如大运、流年、行业五行等）。主席会将问题转达给用户。",
          parameter_schema: [
            question: [
              type: :string,
              required: true,
              doc: "The question to ask the user for supplementary information."
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        question = args["question"] || args[:question]

        Comms.publish(
          "rho.bazi.#{session_id}.user_info.requested",
          %{
            session_id: session_id,
            agent_id: agent_id,
            from_advisor: role,
            question: question
          },
          source: "/session/#{session_id}/agent/#{agent_id}"
        )

        {:ok, "Question submitted to Chairman: #{question}"}
      end
    }
  end
end
