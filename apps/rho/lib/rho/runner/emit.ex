defmodule Rho.Runner.Emit do
  @moduledoc """
  Emit callback resolution and tape recording for runner events.

  `Rho.Runner` owns loop control; this module owns the event-side effects
  attached to a runtime.
  """

  require Logger

  @doc "Resolves legacy runner event callback options into a single emit function."
  def resolve(opts) when is_list(opts) do
    case {opts[:emit], opts[:on_event], opts[:on_text]} do
      {emit, _, _} when is_function(emit) ->
        emit

      {_, on_event, on_text} when is_function(on_event) or is_function(on_text) ->
        fn
          %{type: :text_delta, text: chunk} when is_function(on_text) ->
            on_text.(chunk)
            :ok

          event when is_function(on_event) ->
            on_event.(event)

          _ ->
            :ok
        end

      _ ->
        fn _event -> :ok end
    end
  end

  def resolve(emit) when is_function(emit), do: emit
  def resolve(_), do: fn _event -> :ok end

  @doc "Wraps an emit callback so durable runner events are appended to tape."
  def wrap_with_tape(raw_emit, nil, _memory_mod, _context, _model, _strategy),
    do: raw_emit

  def wrap_with_tape(raw_emit, tape_name, memory_mod, context, model, strategy) do
    fn event ->
      maybe_append_to_tape(event, tape_name, memory_mod, context, model, strategy)
      raw_emit.(event)
    end
  end

  defp maybe_append_to_tape(event, tape_name, memory_mod, context, model, strategy) do
    if event.type not in [:llm_text, :tool_start, :tool_result] do
      t_tape = System.monotonic_time(:millisecond)

      append_event_with_meta(
        memory_mod,
        tape_name,
        event,
        event_meta(context, model, strategy, event)
      )

      tape_ms = System.monotonic_time(:millisecond) - t_tape

      warn_if_slow(
        tape_ms,
        2_000,
        "[runner.emit] tape append took #{tape_ms}ms for #{event.type}"
      )
    end
  end

  defp append_event_with_meta(memory_mod, tape_name, event, meta) do
    case event_to_entry(event) do
      nil -> :ok
      {kind, payload} -> append_mem(memory_mod, tape_name, kind, payload, meta)
    end
  end

  defp append_mem(memory_mod, tape_name, kind, payload, meta) do
    if function_exported?(memory_mod, :append, 4) do
      memory_mod.append(tape_name, kind, payload, meta)
    else
      memory_mod.append(tape_name, kind, payload)
    end
  end

  defp event_to_entry(%{type: :llm_usage} = event) do
    usage = event[:usage] || %{}

    {:event,
     %{
       "name" => "llm_usage",
       "step" => event[:step],
       "model" => to_string(event[:model] || ""),
       "input_tokens" => get_usage(usage, :input_tokens),
       "output_tokens" => get_usage(usage, :output_tokens),
       "reasoning_tokens" => get_usage(usage, :reasoning_tokens),
       "cached_tokens" => get_usage(usage, :cached_tokens),
       "cache_creation_tokens" => get_usage(usage, :cache_creation_tokens),
       "total_tokens" => get_usage(usage, :total_tokens),
       "total_cost" => get_usage(usage, :total_cost),
       "input_cost" => get_usage(usage, :input_cost),
       "output_cost" => get_usage(usage, :output_cost),
       "reasoning_cost" => get_usage(usage, :reasoning_cost)
     }}
  end

  defp event_to_entry(%{type: :error, reason: reason}) do
    {:event, %{"name" => "error", "reason" => inspect(reason)}}
  end

  defp event_to_entry(%{type: :compact} = event) do
    {:event, %{"name" => "compact", "tape_name" => event[:tape_name]}}
  end

  defp event_to_entry(_event), do: nil

  defp get_usage(usage, key) do
    Map.get(usage, key) || Map.get(usage, to_string(key), 0)
  end

  defp event_meta(context, model, strategy, event) do
    base_meta(context, model, strategy)
    |> maybe_put_meta("turn_id", event[:turn_id] || context.turn_id)
    |> maybe_put_meta("step", event[:step])
  end

  defp base_meta(context, model, strategy) do
    %{}
    |> maybe_put_meta("conversation_id", context.conversation_id)
    |> maybe_put_meta("thread_id", context.thread_id)
    |> maybe_put_meta("session_id", context.session_id)
    |> maybe_put_meta("agent_id", context.agent_id)
    |> maybe_put_meta("model", model && to_string(model))
    |> maybe_put_meta("strategy", inspect(strategy))
  end

  defp maybe_put_meta(map, _key, nil), do: map
  defp maybe_put_meta(map, _key, ""), do: map
  defp maybe_put_meta(map, key, value), do: Map.put(map, key, value)

  defp warn_if_slow(duration_ms, threshold, message) do
    if duration_ms > threshold, do: Logger.warning(message)
  end
end
