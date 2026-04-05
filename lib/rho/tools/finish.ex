defmodule Rho.Tools.Finish do
  @moduledoc "Tool for subagents to signal task completion."

  def tool_def do
    %{
      tool:
        ReqLLM.tool(
          name: "finish",
          description:
            "Call this when your task is complete. Pass your final result. " <>
              "This is the only way to return your output to the parent agent.",
          parameter_schema: [
            result: [
              type: :string,
              required: true,
              doc: "Your final result to return to the parent"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        {:final, args["result"] || args[:result] || "done"}
      end
    }
  end
end
