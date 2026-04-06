defmodule RhoWeb.ArgFormatter do
  @moduledoc """
  Prettifies tool-call argument maps for display in the chat UI.

  Models often stuff JSON payloads into string-typed tool parameters
  (e.g. `rows_json: "[{\"name\":\"Alice\"}]"` on `add_rows`). The raw
  view shows a double-escaped string. This module lenient-parses those
  inner payloads so the UI can render them as structured JSON.

  Eligible field names: anything ending in `_json`, `_raw`, `_payload`,
  plus the literal key `arguments` (OpenAI-style tool_calls). Parsing
  is best-effort via `Rho.Parse.Lenient.parse/1`; fields that fail to
  decode stay in the remaining-args map untouched.
  """

  @doc """
  Walks `args` and extracts inner-JSON string fields. Returns
  `{labelled_parts, remaining_args}` where each `labelled_part` is a
  `{label, pretty_json_text, lang}` triple ready for rendering.
  """
  @spec extract_inner_json(map()) :: {[{String.t(), String.t(), String.t()}], map()}
  def extract_inner_json(args) when is_map(args) do
    Enum.reduce(args, {[], %{}}, fn {k, v}, {parts, rest} ->
      k_str = to_string(k)

      if inner_json_key?(k_str) and is_binary(v) do
        case Rho.Parse.Lenient.parse(v) do
          {:ok, decoded} ->
            label = inner_json_label(k_str)
            pretty = Jason.encode!(decoded, pretty: true)
            {parts ++ [{label, pretty, "json"}], rest}

          _ ->
            {parts, Map.put(rest, k, v)}
        end
      else
        {parts, Map.put(rest, k, v)}
      end
    end)
  end

  @doc "Returns true if a key name is eligible for inner-JSON extraction."
  def inner_json_key?(k) when is_binary(k) do
    String.ends_with?(k, "_json") or
      String.ends_with?(k, "_raw") or
      String.ends_with?(k, "_payload") or
      k == "arguments"
  end

  @doc "Strip the conventional suffix from an inner-JSON field name for display."
  def inner_json_label(k) when is_binary(k) do
    stripped =
      k
      |> String.replace_suffix("_json", "")
      |> String.replace_suffix("_raw", "")
      |> String.replace_suffix("_payload", "")

    if stripped == "", do: k, else: stripped
  end
end
