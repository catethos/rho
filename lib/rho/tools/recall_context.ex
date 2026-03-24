defmodule Rho.Tools.RecallContext do
  @moduledoc "Tool for recalling summaries from previous conversation phases (anchors)."

  def tool_def(tape_name) do
    %{
      tool:
        ReqLLM.tool(
          name: "recall_context",
          description:
            "Retrieve summaries from previous conversation phases. " <>
              "Use when you need to remember what happened in earlier phases " <>
              "without the full message history. Call with no arguments to list all phases, " <>
              "or provide a phase name to get its details.",
          parameter_schema: [
            phase: [type: :string, doc: "Phase name to recall (omit to list all phases)"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args -> execute(args, tape_name) end
    }
  end

  defp execute(args, tape_name) do
    phase = args["phase"] || args[:phase]
    entries = Rho.Tape.Store.read(tape_name)
    anchors = Enum.filter(entries, &(&1.kind == :anchor))

    # Exclude the bootstrap anchor (has no meaningful summary)
    anchors = Enum.reject(anchors, fn a ->
      a.payload["name"] == "bootstrap" && (a.payload["state"]["summary"] || "") == ""
    end)

    if phase do
      recall_phase(anchors, phase)
    else
      list_phases(anchors)
    end
  end

  defp list_phases([]) do
    {:ok, "No previous phases found."}
  end

  defp list_phases(anchors) do
    formatted =
      Enum.map_join(anchors, "\n", fn a ->
        state = a.payload["state"] || %{}
        name = state["phase"] || a.payload["name"] || "unknown"
        summary = state["summary"] || ""
        preview = if String.length(summary) > 100, do: String.slice(summary, 0, 100) <> "...", else: summary
        "- #{name}: #{preview}"
      end)

    {:ok, "Previous phases:\n#{formatted}"}
  end

  defp recall_phase(anchors, phase) do
    match =
      Enum.find(anchors, fn a ->
        state = a.payload["state"] || %{}
        (state["phase"] || a.payload["name"]) == phase
      end)

    case match do
      nil ->
        names = Enum.map(anchors, fn a ->
          state = a.payload["state"] || %{}
          state["phase"] || a.payload["name"] || "unknown"
        end)
        {:ok, "Phase \"#{phase}\" not found. Available: #{Enum.join(names, ", ")}"}

      anchor ->
        state = anchor.payload["state"] || %{}
        summary = state["summary"] || "No summary."
        next_steps = state["next_steps"] || []

        parts = ["Phase: #{phase}", "Summary: #{summary}"]
        parts = if next_steps != [], do: parts ++ ["Next steps: #{Enum.join(next_steps, ", ")}"], else: parts

        {:ok, Enum.join(parts, "\n")}
    end
  end
end
