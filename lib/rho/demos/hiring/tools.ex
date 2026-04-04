defmodule Rho.Demos.Hiring.Tools do
  @moduledoc """
  Hiring-specific tools for evaluator agents.
  """

  alias Rho.Comms

  def submit_scores_tool(session_id, agent_id, role) do
    %{
      tool:
        ReqLLM.tool(
          name: "submit_scores",
          description:
            "Submit your candidate scores for the current round. Call this once with all scores.",
          parameter_schema: [
            round: [type: :integer, required: true, doc: "Current round number (1 or 2)"],
            scores: [
              type: :string,
              required: true,
              doc:
                ~s|JSON array: [{"id": "C01", "score": 85, "rationale": "..."}, ...]. Score each of the 5 candidates (C01, C02, C03, C04, C05) from 0-100. Only these IDs are valid.|
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        round = args["round"] || args[:round]
        raw_scores = args["scores"] || args[:scores]

        valid_ids = MapSet.new(Rho.Demos.Hiring.Candidates.all(), & &1.id)

        case Jason.decode(raw_scores) do
          {:ok, scores} when is_list(scores) ->
            scores = Enum.filter(scores, &MapSet.member?(valid_ids, &1["id"]))

            Comms.publish("rho.hiring.#{session_id}.scores.submitted", %{
              session_id: session_id,
              agent_id: agent_id,
              role: role,
              round: round,
              scores: scores
            }, source: "/session/#{session_id}/agent/#{agent_id}")

            {:ok, "Scores submitted for round #{round}: #{length(scores)} candidates scored."}

          _ ->
            {:error,
             "Invalid scores format. Must be a JSON array of {id, score, rationale} objects."}
        end
      end
    }
  end
end
