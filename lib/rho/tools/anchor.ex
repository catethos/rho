defmodule Rho.Tools.Anchor do
  @moduledoc "Tool for creating tape anchors (phase transitions)."

  @doc """
  Returns a tool definition map for the agent loop.
  Takes `tape_name` to inject via closure — the LLM doesn't need to know it.
  """
  def tool_def(tape_name) do
    %{
      tool:
        ReqLLM.tool(
          name: "create_anchor",
          description:
            "Mark a phase transition. Use when shifting from one task phase to another " <>
              "(e.g., discovery → implementation → verification). This compresses older context " <>
              "and starts a fresh working window.",
          parameter_schema: [
            name: [type: :string, required: true, doc: "Phase name (e.g., 'discovery', 'implement', 'verify')"],
            summary: [type: :string, required: true, doc: "Summary of what happened before this point"],
            next_steps: [type: {:list, :string}, doc: "Suggested next actions"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args -> execute(args, tape_name) end
    }
  end

  defp execute(args, tape_name) do
    name = args["name"] || args[:name] || "checkpoint"
    summary = args["summary"] || args[:summary] || ""
    next_steps = args["next_steps"] || args[:next_steps] || []

    case Rho.Tape.Service.handoff(tape_name, name, summary, next_steps: next_steps) do
      {:ok, _entry} ->
        {:ok, "Anchor '#{name}' created. Context window has been refreshed. STOP here and wait for the user's next message — do not continue from the previous context."}

      {:error, reason} ->
        {:error, "Failed to create anchor: #{inspect(reason)}"}
    end
  end
end
