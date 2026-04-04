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
  defp summarize(model, view, gen_opts), do: summarize(model, view, gen_opts, 1)

  defp summarize(model, view, gen_opts, attempt) do
    messages = View.to_messages(view)

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
        if attempt <= 3 and retryable_compact?(reason) do
          require Logger
          Logger.warning("[compact] attempt #{attempt} failed: #{inspect(reason)}, retrying...")
          Process.sleep(1_000 * attempt)
          summarize(model, view, gen_opts, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  defp retryable_compact?(%RuntimeError{message: msg}), do: String.contains?(msg, "Finch")
  defp retryable_compact?({:error, err}), do: retryable_compact?(err)
  defp retryable_compact?(_), do: false
end
