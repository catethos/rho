defmodule Rho.Parse.Lenient do
  @moduledoc """
  Lenient JSON parser for LLM output.

  Pure Elixir, no NIF. Two entry points:

  - `parse/1` — strip markdown fences, decode via `Jason`.
  - `parse_partial/1` — additionally auto-close unclosed `{`, `[`, `"` at EOF
    to make streaming prefixes parseable.

  This is deliberately small (~80 LOC). The upgrade path to a native streaming
  parser stays open (see `docs/archive/superseded/reasoner-baml-plan.md`) but is not built until
  production metrics demand it.
  """

  @doc """
  Parse a complete LLM response containing JSON. Strips markdown fences then
  decodes with `Jason`. Returns `{:ok, term}` or `{:error, reason}`.
  """
  def parse(text) when is_binary(text) do
    emit_telemetry(
      fn ->
        text |> strip_fences() |> Jason.decode()
      end,
      text,
      false
    )
  end

  @doc """
  Parse a partial/streaming JSON prefix. Strips fences, auto-closes unclosed
  structures, then decodes. Never raises.
  """
  def parse_partial(text) when is_binary(text) do
    emit_telemetry(
      fn ->
        text |> strip_fences() |> auto_close() |> Jason.decode()
      end,
      text,
      true
    )
  end

  @doc "Strip leading/trailing markdown fences (```json / ```)."
  def strip_fences(text) when is_binary(text) do
    text
    |> String.replace(~r/\A\s*```(?:json)?\s*\n?/, "")
    |> String.replace(~r/\n?\s*```\s*\z/, "")
    |> String.trim()
  end

  @doc """
  Append closers for unclosed `{`, `[`, and `"` at EOF.

  Conservative: tracks in-string state and escape state so quotes/braces
  inside strings don't mis-count. If the final char is inside an incomplete
  string, closes the string first, then appends `]` and `}` closers.
  """
  def auto_close(text) when is_binary(text) do
    {braces, brackets, in_string} = scan(text, 0, 0, false, false)

    closed =
      if in_string, do: text <> "\"", else: text

    closed
    |> append(String.duplicate("]", brackets))
    |> append(String.duplicate("}", braces))
  end

  # Scan the text, tracking depth of {, [, and in-string state.
  # Returns {unclosed_braces, unclosed_brackets, ends_in_string?}.
  defp scan(<<>>, braces, brackets, in_string, _escape),
    do: {braces, brackets, in_string}

  # Inside an escape sequence — consume next byte and clear escape
  defp scan(<<_c, rest::binary>>, braces, brackets, in_string, true),
    do: scan(rest, braces, brackets, in_string, false)

  # Backslash inside a string starts an escape
  defp scan(<<?\\, rest::binary>>, braces, brackets, true, false),
    do: scan(rest, braces, brackets, true, true)

  # Quote toggles in-string state
  defp scan(<<?", rest::binary>>, braces, brackets, in_string, false),
    do: scan(rest, braces, brackets, not in_string, false)

  # Inside a string: consume without counting structural chars
  defp scan(<<_c, rest::binary>>, braces, brackets, true, false),
    do: scan(rest, braces, brackets, true, false)

  # Outside strings: count structural tokens
  defp scan(<<?{, rest::binary>>, braces, brackets, false, false),
    do: scan(rest, braces + 1, brackets, false, false)

  defp scan(<<?}, rest::binary>>, braces, brackets, false, false),
    do: scan(rest, max(braces - 1, 0), brackets, false, false)

  defp scan(<<?[, rest::binary>>, braces, brackets, false, false),
    do: scan(rest, braces, brackets + 1, false, false)

  defp scan(<<?], rest::binary>>, braces, brackets, false, false),
    do: scan(rest, braces, max(brackets - 1, 0), false, false)

  defp scan(<<_c, rest::binary>>, braces, brackets, false, false),
    do: scan(rest, braces, brackets, false, false)

  defp append(text, ""), do: text
  defp append(text, suffix), do: text <> suffix

  defp emit_telemetry(fun, text, partial?) do
    t0 = System.monotonic_time(:microsecond)
    result = fun.()
    dt = System.monotonic_time(:microsecond) - t0

    outcome =
      case result do
        {:ok, _} -> :ok
        _ -> :error
      end

    :telemetry.execute(
      [:rho, :parse, :lenient, :parse],
      %{duration_us: dt, bytes: byte_size(text)},
      %{outcome: outcome, partial?: partial?}
    )

    result
  end
end
