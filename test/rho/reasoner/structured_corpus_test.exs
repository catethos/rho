defmodule Rho.Reasoner.StructuredCorpusTest do
  @moduledoc """
  Baseline corpus regression for `:structured`. Replays every
  `test/fixtures/parse_corpus/*.txt` fixture through the structured
  reasoner and records the heuristic-hit total.

  This test does not assert a specific hit count — the corpus is a
  rolling record of real-session LLM responses and the heuristic tally
  drifts as new fixtures are mined. It documents the baseline so a
  future change to `Rho.Reasoner.Structured` can be weighed against
  the historical pain level.
  """

  use ExUnit.Case, async: true
  use Mimic

  alias Rho.Reasoner.Structured
  alias Rho.Test.ReasonerHarness

  setup :verify_on_exit!
  setup :set_mimic_from_context

  @corpus_dir "test/fixtures/parse_corpus"

  defp permissive_tool(name, fields) do
    schema =
      Enum.map(fields, fn f -> {String.to_atom(f), [type: :any, required: false]} end)

    %{
      tool:
        ReqLLM.tool(
          name: name,
          description: "permissive corpus tool",
          parameter_schema: schema ++ [{:__extra__, [type: :any, required: false]}],
          callback: fn _ -> :ok end
        ),
      execute: fn _ -> {:ok, "ok"} end
    }
  end

  defp infer_tools(text) do
    stripped = Rho.Parse.Lenient.strip_fences(text)

    case Jason.decode(stripped) do
      {:ok, %{"action" => action} = m} when is_binary(action) ->
        inner = m["action_input"] || m
        fields = if is_map(inner), do: Map.keys(inner), else: []
        [permissive_tool(action, fields)]

      _ ->
        [permissive_tool("noop", ["x"])]
    end
  end

  @fixtures File.ls!(@corpus_dir)
            |> Enum.filter(&String.ends_with?(&1, ".txt"))
            |> Enum.sort()

  describe "structured reasoner baseline on real corpus" do
    test "structured dispatches over the corpus and records heuristic totals" do
      totals =
        Enum.reduce(@fixtures, {0, 0}, fn fixture, {s_h, s_r} ->
          text = File.read!(Path.join(@corpus_dir, fixture))
          tools = infer_tools(text)

          s = ReasonerHarness.run(Structured, text, tools)

          {s_h + s.heuristic_hits, s_r + s.reprompts}
        end)

      {s_hits, s_reprompts} = totals

      # Document the baseline for visibility in test output.
      IO.puts(
        "[corpus] fixtures=#{length(@fixtures)} " <>
          "structured: hits=#{s_hits} reprompts=#{s_reprompts}"
      )

      assert s_hits >= 0
      assert s_reprompts >= 0
    end
  end
end
