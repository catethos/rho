defmodule RhoFrameworks.Demos.Hiring.Tools do
  @moduledoc """
  Hiring-specific tools for evaluator agents.
  """

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
                ~s(JSON array: [{"id": "C01", "score": 85, "rationale": "..."}, ...]. Score each candidate 0-100.)
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        rounded = Rho.MapAccess.get(args, :round)
        raw_scores = Rho.MapAccess.get(args, :scores)

        case Jason.decode(raw_scores) do
          {:ok, scores} when is_list(scores) ->
            Rho.Events.broadcast(
              session_id,
              Rho.Events.event(:hiring_scores_submitted, session_id, agent_id, %{
                role: role,
                round: rounded,
                scores: scores
              })
            )

            {:ok, "Scores submitted for round #{rounded}: #{length(scores)} candidates scored."}

          _ ->
            {:error,
             "Invalid scores format. Must be a JSON array of {id, score, rationale} objects."}
        end
      end
    }
  end
end
