defmodule Rho.Stdlib.Tools.Anchor do
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
            name: [
              type: :string,
              required: true,
              doc: "Phase name (e.g., 'discovery', 'implement', 'verify')"
            ],
            summary: [
              type: :string,
              required: true,
              doc: "Summary of what happened before this point"
            ],
            next_steps: [type: {:list, :string}, doc: "Suggested next actions"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx -> execute(args, tape_name) end
    }
  end

  defp execute(args, tape_name) do
    name = args[:name] || "checkpoint"
    summary = args[:summary] || ""
    next_steps = args[:next_steps] || []

    case Rho.Tape.Service.handoff(tape_name, name, summary, next_steps: next_steps) do
      {:ok, _entry} ->
        {:final,
         "Anchor '#{name}' created. Context window has been refreshed. STOP here and wait for the user's next message — do not continue from the previous context."}

      {:error, reason} ->
        {:error, {:anchor_failed, "Failed to create anchor: #{inspect(reason)}"}}
    end
  end
end

defmodule Rho.Stdlib.Tools.SearchHistory do
  @moduledoc "Tool for searching conversation history across all phases."

  def tool_def(tape_name) do
    %{
      tool:
        ReqLLM.tool(
          name: "search_history",
          description:
            "Search past conversation messages by keyword, including messages from before " <>
              "the current phase (before anchors). Use when the user references something " <>
              "discussed earlier that is no longer in the current context window.",
          parameter_schema: [
            query: [type: :string, required: true, doc: "Keyword or phrase to search for"],
            limit: [type: :integer, doc: "Max results to return (default: 10)"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx -> execute(args, tape_name) end
    }
  end

  defp execute(args, tape_name) do
    query = args[:query] || ""
    limit = args[:limit] || 10

    if String.trim(query) == "" do
      {:error, {:invalid_args, "query is required"}}
    else
      results = Rho.Tape.Service.search(tape_name, query, limit)
      format_search_results(results, query)
    end
  end

  defp format_search_results([], query) do
    {:ok, "No messages found matching \"#{query}\"."}
  end

  defp format_search_results(results, _query) do
    formatted =
      Enum.map_join(results, "\n---\n", fn entry ->
        role = entry.payload["role"] || "unknown"
        content = entry.payload["content"] || ""
        "[#{role}] #{content}"
      end)

    {:ok, "Found #{length(results)} result(s):\n#{formatted}"}
  end
end

defmodule Rho.Stdlib.Tools.RecallContext do
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
      execute: fn args, _ctx -> execute(args, tape_name) end
    }
  end

  defp execute(args, tape_name) do
    phase = args[:phase]
    entries = Rho.Tape.Store.read(tape_name)
    anchors = Enum.filter(entries, &(&1.kind == :anchor))

    # Exclude the bootstrap anchor (has no meaningful summary)
    anchors =
      Enum.reject(anchors, fn a ->
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

        preview =
          if String.length(summary) > 100,
            do: String.slice(summary, 0, 100) <> "...",
            else: summary

        "- #{name}: #{preview}"
      end)

    {:ok, "Previous phases:\n#{formatted}"}
  end

  defp recall_phase(anchors, phase) do
    match =
      Enum.find(anchors, fn a ->
        anchor_phase_name(a) == phase
      end)

    case match do
      nil ->
        names = Enum.map(anchors, &anchor_phase_name/1)
        {:ok, "Phase \"#{phase}\" not found. Available: #{Enum.join(names, ", ")}"}

      anchor ->
        format_phase_detail(anchor, phase)
    end
  end

  defp anchor_phase_name(anchor) do
    state = anchor.payload["state"] || %{}
    state["phase"] || anchor.payload["name"] || "unknown"
  end

  defp format_phase_detail(anchor, phase) do
    state = anchor.payload["state"] || %{}
    summary = state["summary"] || "No summary."
    next_steps = state["next_steps"] || []

    parts = ["Phase: #{phase}", "Summary: #{summary}"]

    parts =
      if next_steps != [],
        do: parts ++ ["Next steps: #{Enum.join(next_steps, ", ")}"],
        else: parts

    {:ok, Enum.join(parts, "\n")}
  end
end

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

      {:final,
       "Memory cleared. All conversation history has been removed and a fresh session started."}
    else
      {:error,
       {:invalid_args, "Please set confirm: true to clear memory. This action cannot be undone."}}
    end
  end
end
