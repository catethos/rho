defmodule Rho.RunnerParseErrorTest do
  use ExUnit.Case
  use Mimic

  setup :verify_on_exit!

  # -- Helpers --
  # TypedStructured uses stream_text → tokens/usage (not process_stream)

  defp stub_stream_text(text) do
    stub(ReqLLM, :stream_text, fn _model, _ctx, _opts ->
      {:ok, {:fake_stream, text}}
    end)

    stub(ReqLLM.StreamResponse, :tokens, fn {:fake_stream, t} -> [t] end)
    stub(ReqLLM.StreamResponse, :usage, fn {:fake_stream, _} -> %{} end)
  end

  defp expect_stream_text_sequence(texts) do
    counter = :counters.new(1, [:atomics])

    expect(ReqLLM, :stream_text, length(texts), fn _model, _ctx, _opts ->
      i = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      text = Enum.at(texts, i)
      {:ok, {:fake_stream, text}}
    end)

    stub(ReqLLM.StreamResponse, :tokens, fn {:fake_stream, t} -> [t] end)
    stub(ReqLLM.StreamResponse, :usage, fn {:fake_stream, _} -> %{} end)
  end

  defp collect_events(fun) do
    table = :ets.new(:test_events, [:ordered_set, :public])
    counter = :counters.new(1, [:atomics])

    on_event = fn event ->
      i = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      :ets.insert(table, {i, event})
      :ok
    end

    result = fun.(on_event)

    events = :ets.tab2list(table) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    :ets.delete(table)
    {result, events}
  end

  # -- Tests --

  describe "parse-error retry via TypedStructured" do
    test "Runner retries on parse_error and succeeds on second attempt" do
      expect_stream_text_sequence([
        # First attempt: triggers parse_error
        "This is not JSON at all",
        # Second attempt: valid response
        ~s({"tool": "respond", "message": "Hello!"})
      ])

      {result, events} =
        collect_events(fn on_event ->
          Rho.Runner.run("mock:model", [ReqLLM.Context.user("hi")],
            turn_strategy: Rho.TurnStrategy.TypedStructured,
            on_event: on_event,
            max_steps: 5
          )
        end)

      assert {:ok, "Hello!"} = result

      # Should have gone through 2 steps
      step_starts = Enum.filter(events, &match?(%{type: :step_start}, &1))
      assert length(step_starts) == 2
    end

    test "parse_error exhausts step budget" do
      stub_stream_text("not json")

      {result, _events} =
        collect_events(fn on_event ->
          Rho.Runner.run("mock:model", [ReqLLM.Context.user("hi")],
            turn_strategy: Rho.TurnStrategy.TypedStructured,
            on_event: on_event,
            max_steps: 2
          )
        end)

      assert {:error, "max steps exceeded (2)"} = result
    end
  end
end
