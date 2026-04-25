defmodule Rho.CLI.Repl do
  @moduledoc """
  CLI REPL adapter. Subscribes to a session and renders events with ANSI formatting.
  The REPL loop runs in a spawned process; this GenServer handles event rendering
  and prompt coordination.
  """
  use GenServer

  defstruct [
    :handle,
    :repl_pid,
    :stop_event,
    :current_turn_id,
    :group_leader,
    :bus_sub_id
  ]

  # --- Public API ---

  @doc "Start the CLI REPL for a session."
  def start_repl(session_id, opts \\ []) do
    GenServer.cast(__MODULE__, {:start, session_id, opts})
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:start, session_id, opts}, state) do
    # Clean up previous session subscription if any
    if state.bus_sub_id, do: Rho.Comms.unsubscribe(state.bus_sub_id)

    stop_event = opts[:stop_event] || self()
    gl = opts[:group_leader]
    session_opts = Keyword.drop(opts, [:stop_event, :group_leader])

    # Start session via unified API
    {:ok, handle} = Rho.Session.start([session_id: session_id] ++ session_opts)

    # Subscribe to signal bus for event rendering
    bus_sub_id =
      case Rho.Comms.subscribe("rho.session.#{session_id}.events.*") do
        {:ok, id} -> id
        _ -> nil
      end

    # Set group leader for IO operations in this GenServer
    if gl, do: Process.group_leader(self(), gl)

    # Start REPL loop
    parent = self()

    repl_pid =
      spawn_link(fn ->
        if gl, do: Process.group_leader(self(), gl)
        repl_loop(parent, stop_event)
      end)

    {:noreply,
     %__MODULE__{
       handle: handle,
       repl_pid: repl_pid,
       stop_event: stop_event,
       group_leader: gl,
       bus_sub_id: bus_sub_id
     }}
  end

  # --- Session events ---

  # Bus delivery — sole event source
  @impl true
  def handle_info({:signal, %Jido.Signal{data: data}}, state) do
    event = normalize_bus_event(data)
    turn_id = bus_turn_id(data)
    render(event)

    state =
      if event.type in [:turn_finished, :turn_cancelled] and turn_id == state.current_turn_id do
        if state.repl_pid, do: send(state.repl_pid, :prompt_ready)
        %{state | current_turn_id: nil}
      else
        state
      end

    {:noreply, state}
  end

  # REPL submitted a line
  def handle_info({:submit, content}, state) do
    {:ok, turn_id} = Rho.Session.send_async(state.handle, content)
    {:noreply, %{state | current_turn_id: turn_id}}
  end

  # REPL hit EOF
  def handle_info(:eof, state) do
    IO.puts("\nBye!")
    if state.stop_event, do: send(state.stop_event, :stop)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Rendering (moved from AgentLoop.default_on_event) ---

  defp render(%{type: :text_delta, text: text}), do: IO.write(text)

  defp render(%{type: :llm_text, text: text}) do
    IO.puts(IO.ANSI.cyan() <> text <> IO.ANSI.reset())
  end

  defp render(%{type: :structured_partial, parsed: parsed}) do
    case parsed do
      %{"action" => action} when is_binary(action) and action != "" ->
        input = parsed["action_input"]

        suffix =
          if is_map(input) and map_size(input) > 0, do: "(#{format_args(input)})", else: "..."

        IO.write(
          "\r" <>
            IO.ANSI.clear_line() <>
            IO.ANSI.faint() <> "  [#{action}] #{suffix}" <> IO.ANSI.reset()
        )

      _ ->
        :ok
    end
  end

  defp render(%{type: :tool_start, name: name, args: args}) do
    # Clear the structured_partial line before showing the final tool_start
    IO.write("\r" <> IO.ANSI.clear_line())
    IO.puts(IO.ANSI.yellow() <> "  [tool] #{name}(#{format_args(args)})" <> IO.ANSI.reset())
  end

  defp render(%{type: :tool_result, status: :ok, output: output}) do
    print_tool_output(output)
  end

  defp render(%{type: :tool_result, status: :error, output: reason}) do
    IO.puts(IO.ANSI.red() <> "  [error] #{reason}" <> IO.ANSI.reset())
  end

  defp render(%{type: :llm_usage, step: step, usage: usage}) when is_map(usage) do
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)
    cached = Map.get(usage, :cached_tokens, 0)
    cache_created = Map.get(usage, :cache_creation_tokens, 0)
    reasoning = Map.get(usage, :reasoning_tokens, 0)
    cost = Map.get(usage, :total_cost)

    extras =
      [
        if(cached > 0, do: "cached: #{cached}"),
        if(cache_created > 0, do: "cache_write: #{cache_created}"),
        if(reasoning > 0, do: "reasoning: #{reasoning}"),
        if(is_number(cost) and cost > 0,
          do: "cost: $#{:erlang.float_to_binary(cost / 1, decimals: 4)}"
        )
      ]
      |> Enum.reject(&is_nil/1)

    line = ["tokens: #{input} in / #{output} out" | extras] |> Enum.join(" | ")
    IO.puts(IO.ANSI.faint() <> "  [step #{step}] #{line}" <> IO.ANSI.reset())
  end

  defp render(%{type: :turn_finished}) do
    IO.puts("")
  end

  defp render(%{type: :turn_cancelled}) do
    IO.puts(IO.ANSI.faint() <> "  [cancelled]" <> IO.ANSI.reset())
  end

  defp render(%{type: :error, reason: reason}) do
    IO.puts(IO.ANSI.red() <> "  [error] #{inspect(reason)}" <> IO.ANSI.reset())
  end

  defp render(%{type: :subagent_progress, subagent_id: sid, step: step, max_steps: max}) do
    IO.puts(IO.ANSI.faint() <> "  [#{sid}] step #{step}/#{max}" <> IO.ANSI.reset())
  end

  defp render(%{type: :subagent_tool, subagent_id: sid, tool_name: name}) do
    IO.puts(IO.ANSI.faint() <> "  [#{sid}] calling #{name}" <> IO.ANSI.reset())
  end

  defp render(%{type: :subagent_error, subagent_id: sid, reason: reason}) do
    IO.puts(IO.ANSI.red() <> "  [#{sid}] error: #{inspect(reason)}" <> IO.ANSI.reset())
  end

  defp render(_event), do: :ok

  # --- REPL loop (runs in spawned process) ---

  defp repl_loop(parent, stop_event) do
    case IO.gets("rho> ") do
      :eof ->
        send(parent, :eof)

      input ->
        content = String.trim(input)

        if content != "" do
          send(parent, {:submit, content})

          receive do
            :prompt_ready -> :ok
          end
        end

        repl_loop(parent, stop_event)
    end
  end

  # --- Helpers ---

  defp format_args(args) when map_size(args) == 0, do: ""

  defp format_args(args) do
    Enum.map_join(args, ", ", fn {k, v} ->
      v_str = to_string(v)
      v_str = if String.length(v_str) > 60, do: String.slice(v_str, 0, 60) <> "...", else: v_str
      "#{k}: #{inspect(v_str)}"
    end)
  end

  defp print_tool_output(output) do
    # Split into at most 21 parts to avoid allocating a huge list for large outputs
    lines = String.split(output, "\n", parts: 21)

    {truncated, suffix} =
      if length(lines) == 21 do
        # 21st element is the unsplit remainder; count its newlines + 1 for remaining lines
        rest = List.last(lines)
        remaining = 1 + (rest |> :binary.matches("\n") |> length())
        {Enum.take(lines, 20), "\n  ... (#{remaining} more lines)"}
      else
        {lines, ""}
      end

    preview = Enum.join(truncated, "\n")

    IO.puts(
      IO.ANSI.faint() <>
        "  " <> String.replace(preview, "\n", "\n  ") <> suffix <> IO.ANSI.reset()
    )
  end

  defp normalize_bus_event(data) when is_map(data) do
    case {Map.get(data, :type), Map.get(data, "type")} do
      {type, _} when is_atom(type) ->
        data

      {nil, type} when is_binary(type) ->
        # Bus payload may arrive with string keys
        Map.put(atomize_shallow(data), :type, String.to_existing_atom(type))

      _ ->
        data
    end
  rescue
    ArgumentError -> data
  end

  defp bus_turn_id(data) when is_map(data),
    do: Map.get(data, :turn_id) || Map.get(data, "turn_id")

  defp atomize_shallow(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> map
  end
end
