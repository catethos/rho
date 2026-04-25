defmodule Rho.TurnStrategy.Direct do
  @moduledoc """
  Standard tool-use strategy: send tools+prompt to the LLM, classify the
  response as an intent. Default TurnStrategy.

  Returns intent tuples — the Runner handles tool execution via
  `Rho.ToolExecutor` and step recording.
  """

  @behaviour Rho.TurnStrategy

  require Logger

  alias Rho.LLM.Admission
  alias Rho.TurnStrategy.Shared

  @impl Rho.TurnStrategy
  def prompt_sections(_tool_defs, _context), do: []

  @impl Rho.TurnStrategy
  def run(projection, runtime) do
    %{context: messages} = projection
    model = runtime.model
    gen_opts = runtime.gen_opts
    emit = runtime.emit

    stream_opts = Keyword.merge([tools: runtime.req_tools], gen_opts)
    process_opts = [on_result: fn chunk -> emit.(%{type: :text_delta, text: chunk}) end]

    Logger.info("[direct] starting LLM stream model=#{model}")
    t_llm_start = System.monotonic_time(:millisecond)

    case stream_with_retry(model, messages, stream_opts, process_opts, emit, 1) do
      {:ok, response} ->
        Logger.info(
          "[direct] LLM stream completed in #{System.monotonic_time(:millisecond) - t_llm_start}ms"
        )

        classify_response(response, projection, runtime)

      {:error, reason} ->
        emit.(%{type: :error, reason: reason})
        {:error, inspect(reason)}
    end
  end

  @impl Rho.TurnStrategy
  def build_tool_step(tool_calls, results, response_text) do
    originals = Enum.map(tool_calls, & &1[:original])
    assistant_msg = ReqLLM.Context.assistant("", tool_calls: originals)

    tool_results =
      Enum.map(results, fn r ->
        ReqLLM.Context.tool_result(r.call_id, r.result)
      end)

    %{
      type: :tool_step,
      assistant_msg: assistant_msg,
      tool_results: tool_results,
      tool_calls: originals,
      response_text: response_text
    }
  end

  # -- Response classification --

  defp classify_response(response, projection, runtime) do
    emit = runtime.emit
    usage = ReqLLM.Response.usage(response)
    step = Map.get(projection, :step)
    emit.(%{type: :llm_usage, step: step, usage: usage, model: runtime.model})

    tool_calls = ReqLLM.Response.tool_calls(response)

    response_data = %{
      text: ReqLLM.Response.text(response),
      tool_calls: tool_calls,
      usage: usage
    }

    case Rho.PluginRegistry.apply_stage(:response_in, response_data, runtime.context) do
      {:halt, reason} ->
        emit.(%{type: :error, reason: {:halt, reason}})
        {:error, {:halt, reason}}

      {:cont, _} ->
        case tool_calls do
          [] ->
            {:respond, ReqLLM.Response.text(response)}

          _ ->
            response_text = ReqLLM.Response.text(response)

            normalized =
              Enum.map(tool_calls, fn tc ->
                %{
                  name: ReqLLM.ToolCall.name(tc),
                  args: ReqLLM.ToolCall.args_map(tc) || %{},
                  call_id: tc.id,
                  original: tc
                }
              end)

            {:call_tools, normalized, response_text}
        end
    end
  end

  # -- Streaming --

  defp stream_with_retry(model, context, stream_opts, process_opts, emit, attempt) do
    stream_opts = Keyword.put_new(stream_opts, :receive_timeout, 120_000)

    result =
      Admission.with_slot(fn -> do_stream(model, context, stream_opts, process_opts) end)

    case result do
      {:ok, _response} = ok ->
        ok

      {:error, :acquire_timeout} = err ->
        Logger.error("[turn_strategy.direct] admission timeout — no LLM slot available after 60s")
        err

      {:error, reason} ->
        maybe_retry_stream(reason, model, context, stream_opts, process_opts, emit, attempt)
    end
  end

  defp do_stream(model, context, stream_opts, process_opts) do
    try do
      case ReqLLM.stream_text(model, context, stream_opts) do
        {:ok, stream_response} ->
          ReqLLM.StreamResponse.process_stream(stream_response, process_opts)

        {:error, _} = err ->
          err
      end
    rescue
      exception ->
        Logger.warning("[turn_strategy.direct] stream raised: #{Exception.message(exception)}")
        {:error, exception}
    end
  end

  defp maybe_retry_stream(reason, model, context, stream_opts, process_opts, emit, attempt) do
    if Shared.should_retry?(reason, attempt) do
      Logger.warning(
        "[turn_strategy.direct] stream failed (attempt #{attempt}): #{inspect(reason)}, retrying..."
      )

      Shared.retry_backoff(attempt)
      stream_with_retry(model, context, stream_opts, process_opts, emit, attempt + 1)
    else
      Logger.error(
        "[turn_strategy.direct] stream FAILED after #{attempt} attempts: #{inspect(reason)} model=#{model}"
      )

      {:error, reason}
    end
  end
end
