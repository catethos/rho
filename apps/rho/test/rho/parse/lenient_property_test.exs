defmodule Rho.Parse.LenientPropertyTest do
  @moduledoc """
  Property-based tests for `Rho.Parse.Lenient`.

    * Round-trip: any JSON-encodable term decodes back to itself after
      `parse/1`.
    * Prefix safety: `parse_partial/1` on any prefix of a valid JSON
      string never raises; returns `{:ok, _}` or `{:error, _}`.
    * Fence invariance: wrapping valid JSON in ```json ... ``` fences
      yields the same parsed result as the unfenced form.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Rho.Parse.Lenient

  # Generator for arbitrary JSON values.
  defp json_scalar do
    one_of([
      constant(nil),
      boolean(),
      integer(),
      float(),
      string(:printable, max_length: 40)
    ])
  end

  defp json_value(depth) when depth <= 0, do: json_scalar()

  defp json_value(depth) do
    one_of([
      json_scalar(),
      list_of(json_value(depth - 1), max_length: 4),
      map_of(string(:alphanumeric, min_length: 1, max_length: 8), json_value(depth - 1),
        max_length: 4
      )
    ])
  end

  defp json_value, do: json_value(3)

  property "round-trip: any encodable JSON parses back to itself" do
    check all(value <- json_value(), max_runs: 200) do
      encoded = Jason.encode!(value)
      assert {:ok, decoded} = Lenient.parse(encoded)
      assert normalize_floats(decoded) == normalize_floats(value)
    end
  end

  property "fence invariance: ```json ... ``` yields identical parse" do
    check all(value <- json_value(), max_runs: 100) do
      encoded = Jason.encode!(value)
      fenced = "```json\n#{encoded}\n```"

      assert {:ok, a} = Lenient.parse(encoded)
      assert {:ok, b} = Lenient.parse(fenced)
      assert a == b
    end
  end

  property "prefix safety: parse_partial never raises on any binary prefix" do
    check all(value <- json_value(), max_runs: 200) do
      encoded = Jason.encode!(value)
      size = byte_size(encoded)

      for i <- 0..size do
        prefix = binary_part(encoded, 0, i)

        result =
          try do
            Lenient.parse_partial(prefix)
          rescue
            e -> {:raised, e}
          end

        assert match?({:ok, _}, result) or match?({:error, _}, result),
               "parse_partial raised on prefix #{inspect(prefix)}: #{inspect(result)}"
      end
    end
  end

  property "prefix safety: parse_partial on arbitrary binary prefixes" do
    # Build prefixes from both valid JSON and arbitrary junk.
    check all(junk <- binary(max_length: 120), max_runs: 200) do
      result =
        try do
          Lenient.parse_partial(junk)
        rescue
          e -> {:raised, e}
        end

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "parse on arbitrary binaries never raises" do
    check all(junk <- binary(max_length: 120), max_runs: 200) do
      result =
        try do
          Lenient.parse(junk)
        rescue
          e -> {:raised, e}
        end

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # -- Helpers --

  # Jason decodes integers-in-JSON as integers and floats as floats;
  # when we generate a float like 0.0 Jason may serialize as "0.0" and
  # decode back to 0.0 exactly. But on some BEAM floats there can be
  # float/integer discrepancies — canonicalize for comparison.
  defp normalize_floats(x) when is_float(x), do: {:float, Float.round(x, 6)}

  defp normalize_floats(x) when is_map(x),
    do: Map.new(x, fn {k, v} -> {k, normalize_floats(v)} end)

  defp normalize_floats(x) when is_list(x), do: Enum.map(x, &normalize_floats/1)
  defp normalize_floats(x), do: x
end
