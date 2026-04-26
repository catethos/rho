defmodule Rho.TurnStrategy.Shared do
  @moduledoc """
  Shared helpers for turn strategy implementations.

  Extracts common patterns used by both `Direct` and `Structured`
  strategies: stream retry logic, error classification, and tool
  execution timeout handling.
  """

  require Logger

  @max_stream_retries 2
  @tool_inactivity_timeout :timer.minutes(2)

  # -- Stream retry --

  @doc """
  Determines whether a stream/connection error is retryable.
  """
  def retryable?(%Mint.TransportError{reason: reason}), do: retryable?(reason)
  def retryable?({:timeout, _}), do: true
  def retryable?({:closed, _}), do: true
  def retryable?(:timeout), do: true
  def retryable?(:closed), do: true
  def retryable?({:http_task_failed, inner}), do: retryable?(inner)
  def retryable?({:http_streaming_failed, inner}), do: retryable?(inner)
  def retryable?({:provider_build_failed, inner}), do: retryable?(inner)
  def retryable?(:stream_inactive), do: true
  def retryable?(:econnrefused), do: true
  def retryable?(:econnreset), do: true

  # Finch pool exhaustion surfaces as a `%RuntimeError{}` with a message
  # starting with "Finch was unable to provide a connection". This is an
  # inherently transient condition — back off and retry rather than
  # crashing the agent loop.
  def retryable?(%RuntimeError{message: msg}) when is_binary(msg) do
    String.contains?(msg, "Finch was unable to provide a connection") or
      String.contains?(msg, "NimblePool") or
      String.contains?(msg, "excess queuing for connections")
  end

  # ReqLLM wraps underlying stream failures in `%ReqLLM.Error.API.Stream{}`
  # with the original error stored on `:cause` (the `:reason` field is a
  # stringified message, not the cause). Unwrap and re-check.
  def retryable?(%{__struct__: ReqLLM.Error.API.Stream, cause: cause}), do: retryable?(cause)

  # `{:error, inner}` and `{:http_task_failed, {:error, inner}}`-style
  # tuples appear in several layers of the stream stack — unwrap once.
  def retryable?({:error, inner}), do: retryable?(inner)

  def retryable?(_), do: false

  @doc """
  Returns `{max_retries, true/false}` for whether a retry should be attempted.
  """
  def should_retry?(reason, attempt) do
    attempt <= @max_stream_retries and retryable?(reason)
  end

  @doc """
  Sleeps for a backoff period proportional to the attempt number.
  """
  def retry_backoff(attempt) do
    Process.sleep(1_000 * attempt)
  end

  # -- Tool execution timeout --

  @doc """
  Awaits a tool execution task with an inactivity timeout.

  Returns the task result on success, or `:timeout` if the task
  exceeds the timeout and is killed.
  """
  def await_tool_with_inactivity(task, timeout \\ @tool_inactivity_timeout) do
    ref = task.ref

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result
    after
      timeout ->
        Task.shutdown(task, :brutal_kill)
        :timeout
    end
  end

  @doc """
  Returns the default tool inactivity timeout in milliseconds.
  """
  def tool_inactivity_timeout, do: @tool_inactivity_timeout

  # -- Tool error classification --

  @doc """
  Classifies a tool error reason into a category atom.

  Legacy shim for tools that still return `{:error, binary}`. Prefer
  `{:error, atom}` or `{:error, {atom, detail}}` — the tool executor
  passes those atoms through directly without string-matching.
  """
  def classify_tool_error(reason) when is_binary(reason) do
    Logger.warning(
      "Tool returned legacy string error: #{inspect(reason)}. " <>
        "Migrate to {:error, atom} or {:error, {atom, detail}} for typed errors."
    )

    reason_down = String.downcase(reason)

    cond do
      String.contains?(reason_down, "timeout") ->
        :timeout

      String.contains?(reason_down, "permission") or String.contains?(reason_down, "denied") ->
        :permission_denied

      String.contains?(reason_down, "not found") or String.contains?(reason_down, "no such") ->
        :not_found

      String.contains?(reason_down, "invalid") or String.contains?(reason_down, "argument") ->
        :invalid_args

      true ->
        :runtime_error
    end
  end

  def classify_tool_error(_), do: :runtime_error
end
