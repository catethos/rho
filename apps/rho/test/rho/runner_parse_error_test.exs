defmodule Rho.RunnerParseErrorTest do
  use ExUnit.Case
  use Mimic

  setup :verify_on_exit!

  # -- Helpers --

  defp stub_baml_response(result_map) when is_map(result_map) do
    stub(RhoBaml.SchemaWriter, :write!, fn _dir, _tool_defs, _opts -> :ok end)

    stub(BamlElixir.Client, :sync_stream, fn _fn_name, _args, _callback, _opts ->
      {:ok, result_map}
    end)
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

  describe "plain text fallback via TypedStructured" do
    test "Runner treats missing tool tag as respond (no retry)" do
      # BAML always returns a parsed map, so "plain text" isn't possible.
      # The equivalent is a map without a "tool" key — dispatch_parsed
      # returns :parse_error, which TypedStructured treats as respond.
      stub_baml_response(%{message: "This is not JSON at all"})

      {result, events} =
        collect_events(fn on_event ->
          Rho.Runner.run("mock:model", [ReqLLM.Context.user("hi")],
            turn_strategy: Rho.TurnStrategy.TypedStructured,
            on_event: on_event,
            max_steps: 5
          )
        end)

      assert {:ok, "This is not JSON at all"} = result

      # Should complete in 1 step (no retry)
      step_starts = Enum.filter(events, &match?(%{type: :step_start}, &1))
      assert match?([_], step_starts)
    end
  end
end
