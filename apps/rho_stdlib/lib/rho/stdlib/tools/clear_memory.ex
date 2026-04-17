defmodule Rho.Stdlib.Tools.ClearMemory do
  @moduledoc "Tool for clearing conversation memory (tape reset)."

  def tool_def(tape_name) do
    %{
      tool:
        ReqLLM.tool(
          name: "clear_memory",
          description:
            "Clear all conversation history and start fresh. " <>
              "This permanently removes all messages, tool calls, and anchors from memory. " <>
              "Use only when explicitly asked by the user to clear or reset the conversation.",
          parameter_schema: [
            archive: [
              type: :boolean,
              doc: "If true, save a backup before clearing (default: true)"
            ],
            confirm: [
              type: :boolean,
              required: true,
              doc: "Must be true to confirm the clear operation"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx -> execute(args, tape_name) end
    }
  end

  defp execute(args, tape_name) do
    confirm = args[:confirm] || false
    archive = if Map.has_key?(args, :archive), do: args[:archive], else: true

    if confirm do
      Rho.Tape.Service.reset(tape_name, archive)

      {:ok,
       "Memory cleared. All conversation history has been removed and a fresh session started."}
    else
      {:error, "Please set confirm: true to clear memory. This action cannot be undone."}
    end
  end
end
