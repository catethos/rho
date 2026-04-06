defmodule Rho.Stdlib.Tools.EndTurn do
  @moduledoc """
  Zero-arg signal tool that tells the agent loop the turn is over.

  Unlike the old `final_response` tool, the LLM writes its answer as normal
  streaming text and calls `end_turn()` alongside it. This means the user
  sees tokens as they arrive instead of waiting for the full tool-call JSON
  to be parsed.
  """

  def tool_def do
    %{
      tool:
        ReqLLM.tool(
          name: "end_turn",
          description:
            "Signal that your response is complete. Write your answer as normal text, " <>
              "then call this tool with no arguments to end the turn. " <>
              "Do NOT put your response inside the tool arguments — just write it as text.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args ->
        {:ok, "turn ended"}
      end
    }
  end
end
