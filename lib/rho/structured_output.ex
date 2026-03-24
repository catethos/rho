defmodule Rho.StructuredOutput do
  @moduledoc """
  Pure-Elixir structured output parsing for LLM responses.

  Ported from the simplify_baml Rust crate. Handles the messy reality of LLM
  JSON output: curly quotes, markdown fences, literal newlines in strings,
  and incomplete streaming JSON.

  Two main entry points:

  - `parse/1` — Parse a complete LLM response, extracting JSON from noise
  - `parse_partial/1` — Parse potentially incomplete JSON (streaming), auto-closing structures
  """

  @doc """
  Parse a complete LLM response that should contain JSON.

  Tries multiple strategies:
  1. Parse raw text as JSON
  2. Normalize curly/smart quotes
  3. Escape control chars in strings
  4. Extract from markdown fences
  5. Find JSON by brace matching

  Returns `{:ok, map}` or `{:error, reason}`.
  """
  def parse(text) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {:error, :empty}
    else
      case try_parse_strategies(trimmed) do
        {:ok, _} = ok -> ok
        :error -> {:error, {:parse_failed, String.slice(trimmed, 0..200)}}
      end
    end
  end

  @doc """
  Parse potentially incomplete JSON from a streaming LLM response.

  Returns:
  - `{:ok, map}` — Successfully parsed (complete or auto-closed)
  - `{:partial, nil}` — Too incomplete, need more data
  - `{:error, reason}` — Unrecoverable error
  """
  def parse_partial(text) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {:partial, nil}
    else
      case try_parse_strategies(trimmed) do
        {:ok, _} = ok ->
          ok

        :error ->
          # Try auto-closing incomplete structures
          escaped = trimmed |> normalize_quotes() |> escape_control_chars()

          # Try markdown extraction + auto-close
          extracted = extract_from_markdown(trimmed)

          results =
            if extracted != trimmed do
              norm_extracted = extracted |> normalize_quotes() |> escape_control_chars()
              generate_completions(norm_extracted) ++ generate_completions(escaped)
            else
              generate_completions(escaped)
            end

          Enum.find_value(results, {:partial, nil}, fn attempt ->
            case Jason.decode(attempt) do
              {:ok, map} when is_map(map) -> {:ok, map}
              {:ok, list} when is_list(list) -> {:ok, list}
              _ -> nil
            end
          end)
      end
    end
  end

  # -- Parse strategies (tried in order) --

  defp try_parse_strategies(text) do
    with :error <- try_decode(text),
         normalized = normalize_quotes(text),
         :error <- try_decode(normalized),
         escaped = escape_control_chars(normalized),
         :error <- try_decode(escaped),
         extracted = extract_from_markdown(text),
         :error <- try_if_different(extracted, text),
         :error <- try_if_different(extracted |> normalize_quotes() |> escape_control_chars(), text),
         :error <- try_merge_objects(escaped),
         :error <- try_brace_scan(escaped) do
      :error
    end
  end

  defp try_decode(text) do
    case Jason.decode(text) do
      {:ok, result} when is_map(result) or is_list(result) -> {:ok, result}
      _ -> :error
    end
  end

  defp try_if_different(text, original) do
    if text != original, do: try_decode(text), else: :error
  end

  # Try extracting JSON by finding first { and scanning } positions from last to first.
  # Handles cases where the LLM emits extra trailing braces.
  defp try_brace_scan(text) do
    case :binary.match(text, "{") do
      {start, _} ->
        close_positions =
          :binary.matches(text, "}")
          |> Enum.map(&elem(&1, 0))
          |> Enum.filter(&(&1 > start))
          |> Enum.reverse()

        Enum.find_value(close_positions, :error, fn end_pos ->
          candidate = binary_part(text, start, end_pos - start + 1)
          case try_decode(candidate) do
            {:ok, _} = ok -> ok
            :error -> nil
          end
        end)

      :nomatch ->
        :error
    end
  end

  # Try merging multiple JSON objects in the text into one.
  # Handles the case where the LLM splits e.g. {"thinking": ...} and {"action": ...}
  # into separate objects.
  defp try_merge_objects(text) do
    objects = extract_json_objects(text)

    if length(objects) >= 2 do
      merged = Enum.reduce(objects, %{}, &Map.merge(&2, &1))
      {:ok, merged}
    else
      :error
    end
  end

  defp extract_json_objects(text) do
    extract_json_objects(text, [])
  end

  defp extract_json_objects(text, acc) do
    case :binary.match(text, "{") do
      {start, _} ->
        rest_from_open = binary_part(text, start, byte_size(text) - start)

        close_positions =
          :binary.matches(rest_from_open, "}")
          |> Enum.map(&elem(&1, 0))

        found =
          Enum.find_value(close_positions, nil, fn end_pos ->
            candidate = binary_part(rest_from_open, 0, end_pos + 1)
            case Jason.decode(candidate) do
              {:ok, map} when is_map(map) -> {map, end_pos + 1}
              _ -> nil
            end
          end)

        case found do
          {map, consumed} ->
            remaining_start = start + consumed
            remaining = binary_part(text, remaining_start, byte_size(text) - remaining_start)
            extract_json_objects(remaining, [map | acc])

          nil ->
            # Skip past this { and try the next one
            next_start = start + 1
            remaining = binary_part(text, next_start, byte_size(text) - next_start)
            extract_json_objects(remaining, acc)
        end

      :nomatch ->
        Enum.reverse(acc)
    end
  end

  # -- Quote normalization --
  # Converts Unicode curly/smart quotes to ASCII ONLY outside string literals.
  # Inside strings, curly quotes are escaped as \".

  def normalize_quotes(text) do
    text
    |> String.graphemes()
    |> normalize_quotes_acc(false, false, [])
    |> IO.iodata_to_binary()
  end

  defp normalize_quotes_acc([], _in_string, _escape, acc), do: Enum.reverse(acc)

  defp normalize_quotes_acc([char | rest], in_string, true, acc) do
    normalize_quotes_acc(rest, in_string, false, [char | acc])
  end

  defp normalize_quotes_acc(["\\" | rest], true = in_string, false, acc) do
    normalize_quotes_acc(rest, in_string, true, ["\\" | acc])
  end

  defp normalize_quotes_acc(["\"" | rest], in_string, false, acc) do
    normalize_quotes_acc(rest, not in_string, false, ["\"" | acc])
  end

  # Inside strings: escape curly quotes
  defp normalize_quotes_acc([char | rest], true, false, acc) when char in ["\u201C", "\u201D"] do
    normalize_quotes_acc(rest, true, false, ["\\\"" | acc])
  end

  defp normalize_quotes_acc([char | rest], true, false, acc) when char in ["\u2018", "\u2019"] do
    normalize_quotes_acc(rest, true, false, ["'" | acc])
  end

  defp normalize_quotes_acc(["\n" | rest], true, false, acc) do
    normalize_quotes_acc(rest, true, false, ["\\n" | acc])
  end

  defp normalize_quotes_acc(["\r" | rest], true, false, acc) do
    normalize_quotes_acc(rest, true, false, ["\\r" | acc])
  end

  defp normalize_quotes_acc(["\t" | rest], true, false, acc) do
    normalize_quotes_acc(rest, true, false, ["\\t" | acc])
  end

  # Outside strings: convert curly quotes to ASCII
  defp normalize_quotes_acc([char | rest], false, false, acc) when char in ["\u201C", "\u201D"] do
    normalize_quotes_acc(rest, false, false, ["\"" | acc])
  end

  defp normalize_quotes_acc([char | rest], false, false, acc) when char in ["\u2018", "\u2019"] do
    normalize_quotes_acc(rest, false, false, ["'" | acc])
  end

  defp normalize_quotes_acc([char | rest], in_string, false, acc) do
    normalize_quotes_acc(rest, in_string, false, [char | acc])
  end

  # -- Escape control chars in strings --

  def escape_control_chars(text) do
    text
    |> String.graphemes()
    |> escape_cc_acc(false, false, [])
    |> IO.iodata_to_binary()
  end

  defp escape_cc_acc([], _in_str, _esc, acc), do: Enum.reverse(acc)

  defp escape_cc_acc([c | rest], in_str, true, acc) do
    escape_cc_acc(rest, in_str, false, [c | acc])
  end

  defp escape_cc_acc(["\\" | rest], true, false, acc) do
    escape_cc_acc(rest, true, true, ["\\" | acc])
  end

  defp escape_cc_acc(["\"" | rest], in_str, false, acc) do
    escape_cc_acc(rest, not in_str, false, ["\"" | acc])
  end

  defp escape_cc_acc(["\n" | rest], true, false, acc) do
    escape_cc_acc(rest, true, false, ["\\n" | acc])
  end

  defp escape_cc_acc(["\r" | rest], true, false, acc) do
    escape_cc_acc(rest, true, false, ["\\r" | acc])
  end

  defp escape_cc_acc(["\t" | rest], true, false, acc) do
    escape_cc_acc(rest, true, false, ["\\t" | acc])
  end

  defp escape_cc_acc([c | rest], in_str, false, acc) do
    escape_cc_acc(rest, in_str, false, [c | acc])
  end

  # -- Markdown extraction --

  def extract_from_markdown(text) do
    lower = String.downcase(text)

    cond do
      # ```json block
      String.contains?(lower, "```json") ->
        extract_fenced(text, lower, "```json", 7)

      # ``` block (no language)
      String.contains?(text, "```") ->
        extract_bare_fence(text)

      # Brace matching
      String.contains?(text, "{") ->
        extract_by_braces(text, "{", "}")

      String.contains?(text, "[") ->
        extract_by_braces(text, "[", "]")

      true ->
        text
    end
  end

  defp extract_fenced(text, lower, marker, marker_len) do
    case :binary.match(lower, marker) do
      {start, _} ->
        json_start = start + marker_len
        rest = binary_part(text, json_start, byte_size(text) - json_start)

        case :binary.match(rest, "```") do
          {end_pos, _} ->
            binary_part(rest, 0, end_pos) |> String.trim()

          :nomatch ->
            String.trim(rest)
        end

      :nomatch ->
        text
    end
  end

  defp extract_bare_fence(text) do
    case :binary.match(text, "```") do
      {start, 3} ->
        content_start = start + 3
        rest = binary_part(text, content_start, byte_size(text) - content_start)

        case :binary.match(rest, "```") do
          {end_pos, _} ->
            content = binary_part(rest, 0, end_pos) |> String.trim()
            if String.starts_with?(content, "{") or String.starts_with?(content, "[") do
              content
            else
              text
            end

          :nomatch ->
            content = String.trim(rest)
            if String.starts_with?(content, "{") or String.starts_with?(content, "[") do
              content
            else
              text
            end
        end

      :nomatch ->
        text
    end
  end

  defp extract_by_braces(text, open, close) do
    case :binary.match(text, open) do
      {start, _} ->
        # Find last matching close brace
        case last_index(text, close) do
          nil ->
            binary_part(text, start, byte_size(text) - start)

          end_pos when end_pos > start ->
            binary_part(text, start, end_pos - start + 1)

          _ ->
            binary_part(text, start, byte_size(text) - start)
        end

      :nomatch ->
        text
    end
  end

  defp last_index(text, char) do
    case :binary.matches(text, char) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  # -- Brace counting (string-aware) --

  def count_braces(text) do
    text
    |> String.to_charlist()
    |> count_braces_acc(false, false, 0, 0, 0, 0)
  end

  defp count_braces_acc([], _, _, ob, cb, obrk, cbrk), do: {ob, cb, obrk, cbrk}

  defp count_braces_acc([_ | rest], in_str, true, ob, cb, obrk, cbrk) do
    count_braces_acc(rest, in_str, false, ob, cb, obrk, cbrk)
  end

  defp count_braces_acc([?\\ | rest], true, false, ob, cb, obrk, cbrk) do
    count_braces_acc(rest, true, true, ob, cb, obrk, cbrk)
  end

  defp count_braces_acc([?" | rest], in_str, false, ob, cb, obrk, cbrk) do
    count_braces_acc(rest, not in_str, false, ob, cb, obrk, cbrk)
  end

  defp count_braces_acc([_ | rest], true, false, ob, cb, obrk, cbrk) do
    count_braces_acc(rest, true, false, ob, cb, obrk, cbrk)
  end

  defp count_braces_acc([?{ | rest], false, false, ob, cb, obrk, cbrk) do
    count_braces_acc(rest, false, false, ob + 1, cb, obrk, cbrk)
  end

  defp count_braces_acc([?} | rest], false, false, ob, cb, obrk, cbrk) do
    count_braces_acc(rest, false, false, ob, cb + 1, obrk, cbrk)
  end

  defp count_braces_acc([?[ | rest], false, false, ob, cb, obrk, cbrk) do
    count_braces_acc(rest, false, false, ob, cb, obrk + 1, cbrk)
  end

  defp count_braces_acc([?] | rest], false, false, ob, cb, obrk, cbrk) do
    count_braces_acc(rest, false, false, ob, cb, obrk, cbrk + 1)
  end

  defp count_braces_acc([_ | rest], false, false, ob, cb, obrk, cbrk) do
    count_braces_acc(rest, false, false, ob, cb, obrk, cbrk)
  end

  # -- Incomplete string detection --

  def has_incomplete_string?(text) do
    text
    |> String.to_charlist()
    |> check_incomplete_string(false, false)
  end

  defp check_incomplete_string([], in_string, _escape), do: in_string

  defp check_incomplete_string([_ | rest], in_string, true) do
    check_incomplete_string(rest, in_string, false)
  end

  defp check_incomplete_string([?\\ | rest], true, false) do
    check_incomplete_string(rest, true, true)
  end

  defp check_incomplete_string([?" | rest], in_string, false) do
    check_incomplete_string(rest, not in_string, false)
  end

  defp check_incomplete_string([_ | rest], in_string, false) do
    check_incomplete_string(rest, in_string, false)
  end

  # -- Completion attempts for partial JSON --

  def generate_completions(json) do
    trimmed = String.trim(json)
    {ob, cb, obrk, cbrk} = count_braces(trimmed)
    missing_braces = max(ob - cb, 0)
    missing_brackets = max(obrk - cbrk, 0)

    # Strategy 1: Close incomplete string + close all structures
    s1 = trimmed
    s1 = if has_incomplete_string?(s1), do: s1 <> "\"", else: s1
    s1 = s1 <> String.duplicate("]", missing_brackets) <> String.duplicate("}", missing_braces)

    # Strategy 2: Handle trailing colon/comma, then close
    s2 = trimmed
    s2_trimmed = String.trim_trailing(s2)

    s2 =
      cond do
        String.ends_with?(s2_trimmed, ":") -> s2 <> "null"
        String.ends_with?(s2_trimmed, ",") -> String.trim_trailing(s2_trimmed, ",")
        true -> s2
      end

    s2 = if has_incomplete_string?(s2), do: s2 <> "\"", else: s2
    s2 = s2 <> String.duplicate("]", missing_brackets) <> String.duplicate("}", missing_braces)

    # Strategy 3: Truncate to last comma, close
    s3 =
      case :binary.matches(trimmed, ",") do
        [] ->
          nil

        matches ->
          {last_comma, _} = List.last(matches)
          truncated = binary_part(trimmed, 0, last_comma) |> String.trim()
          truncated <> String.duplicate("]", missing_brackets) <> String.duplicate("}", missing_braces)
      end

    [s1, s2 | if(s3, do: [s3], else: [])]
  end
end
