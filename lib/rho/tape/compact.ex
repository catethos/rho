defmodule Rho.Tape.Compact do
  @moduledoc """
  Context compaction: shrinks the default read set by creating a new anchor.
  Entries before the anchor are preserved but excluded from the default view.

  Compaction is a system-initiated handoff — triggered when context approaches
  the window limit. It asks the LLM to produce a summary, then writes that
  as an anchor.
  """

  alias Rho.Tape.{Service, View}

  @doc """
  Checks whether compaction is needed based on estimated token count.

  Returns `true` if the current view's estimated tokens exceed the threshold.
  """
  def needed?(tape_name, opts \\ []) do
    threshold = opts[:threshold] || 100_000
    view = View.default(tape_name)

    Enum.reduce_while(view.entries, 0, fn entry, acc ->
      content = entry.payload["content"] || entry.payload["output"] || inspect(entry.payload)
      new_acc = acc + div(String.length(content), 4)
      if new_acc > threshold, do: {:halt, true}, else: {:cont, new_acc}
    end) == true
  end

  @doc """
  Estimates the token count of the current view's content.
  Uses a rough heuristic of 1 token per 4 characters.
  """
  def estimate_tokens(tape_name) do
    view = View.default(tape_name)

    view.entries
    |> Enum.map(fn entry ->
      content = entry.payload["content"] || entry.payload["output"] || inspect(entry.payload)
      div(String.length(content), 4)
    end)
    |> Enum.sum()
  end

  @doc """
  Runs compaction: asks the LLM to summarize the current context,
  then writes a handoff anchor with that summary.

  ## Options
    * `:model` - the LLM model to use for summarization (required)
    * `:threshold` - token threshold (default: 100_000)
    * `:gen_opts` - additional options passed to ReqLLM.generate_text
  """
  def run(tape_name, opts \\ []) do
    model = opts[:model] || raise "Compact.run requires :model option"
    gen_opts = opts[:gen_opts] || []

    view = View.default(tape_name)

    if view.entries == [] do
      {:ok, :no_entries}
    else
      case summarize(model, view, gen_opts) do
        {:ok, summary} ->
          Service.handoff(tape_name, "compact", summary, owner: "system")

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Compacts only if the estimated token count exceeds the threshold.
  Returns `{:ok, :not_needed}` if below threshold.
  """
  def run_if_needed(tape_name, opts \\ []) do
    if needed?(tape_name, opts) do
      run(tape_name, opts)
    else
      {:ok, :not_needed}
    end
  end

  # Asks the LLM to produce a concise summary of the current view.
  # Truncates large messages to fit within model context limits.
  @max_compact_chars 400_000

  defp summarize(model, view, gen_opts) do
    messages =
      view
      |> View.to_messages()
      |> truncate_messages(@max_compact_chars)

    prompt =
      ReqLLM.Context.user(
        "Summarize the conversation so far in a concise paragraph. " <>
          "Focus on: what was accomplished, key decisions made, and current state. " <>
          "This summary will replace the detailed history in the context window."
      )

    all_messages = [
      ReqLLM.Context.system("You are a precise summarizer. Produce a single concise paragraph.")
      | messages ++ [prompt]
    ]

    case ReqLLM.generate_text(model, all_messages, gen_opts) do
      {:ok, response} ->
        {:ok, ReqLLM.Response.text(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Truncate individual message content that's too large (e.g., file uploads, big tool results).
  # Keeps the first/last bits so the summarizer knows what happened without the full payload.
  defp truncate_messages(messages, max_total_chars) do
    {truncated, _remaining} =
      Enum.map_reduce(messages, max_total_chars, fn msg, budget ->
        content = msg_content(msg)
        len = String.length(content)

        if len > 2000 and len > budget do
          # Truncate this message, keeping head + tail for context
          snippet =
            String.slice(content, 0, 500) <>
              "\n\n[... #{len} chars truncated for compaction ...]\n\n" <>
              String.slice(content, -200, 200)

          {put_content(msg, snippet), budget}
        else
          {msg, budget - len}
        end
      end)

    truncated
  end

  defp msg_content(%{content: content}) when is_binary(content), do: content

  defp msg_content(%{content: parts}) when is_list(parts) do
    Enum.map_reduce(parts, "", fn
      %{text: t}, acc when is_binary(t) -> {t, acc <> t}
      _, acc -> {"", acc}
    end)
    |> elem(1)
  end

  defp msg_content(_), do: ""

  defp put_content(%{content: c} = msg, new) when is_binary(c), do: %{msg | content: new}

  defp put_content(%{content: [%{text: _} = first | _]} = msg, new),
    do: %{msg | content: [%{first | text: new}]}

  defp put_content(msg, _new), do: msg
end
