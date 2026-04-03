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
            "提交你建议的评分维度。请根据用户的问题提出3-5个相关的评分维度。",
          parameter_schema: [
            dimensions: [
              type: :string,
              required: true,
              doc: "JSON array of dimension name strings, e.g. [\"财运\", \"事业\", \"健康\"]."
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        raw = args["dimensions"] || args[:dimensions]

        case Jason.decode(raw) do
          {:ok, dimensions} when is_list(dimensions) ->
            Comms.publish(
              "rho.bazi.#{session_id}.dimensions.proposed",
              %{
                session_id: session_id,
                agent_id: agent_id,
                role: role,
                dimensions: dimensions
              },
              source: "/session/#{session_id}/agent/#{agent_id}"
            )

            {:ok, "Dimensions submitted: #{Enum.join(dimensions, ", ")}."}

          {:ok, _} ->
            {:error, "Invalid dimensions format. Must be a JSON array of strings."}

          _ ->
            {:error, "Invalid dimensions format. Must be a valid JSON array."}
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
            "提交对每个选项在各维度上的评分。每个维度0-100分，并附上理由。",
          parameter_schema: [
            round: [type: :integer, required: true, doc: "Current round number (1 or 2)."],
            scores: [
              type: :string,
              required: true,
              doc:
                ~s|JSON object grouped by option, e.g. {"option_a": {"财运": 80, "rationale": "..."}}.|
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        round = args["round"] || args[:round]
        raw_scores = args["scores"] || args[:scores]

        case Jason.decode(raw_scores) do
          {:ok, scores} when is_map(scores) ->
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

            {:ok, "Scores submitted for round #{round}."}

          {:ok, _} ->
            {:error, "Invalid scores format. Must be a JSON object grouped by option."}

          _ ->
            {:error, "Invalid scores format. Must be a valid JSON object."}
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
