defmodule RhoWeb.StreamEnvelope do
  @moduledoc """
  Detects and decodes JSON-envelope shapes in streaming assistant text
  (partial output from `Rho.Reasoner.Structured`). Used to render a
  human-readable preview of a tool/action dispatch while the model is
  still mid-stream, instead of showing raw escaped JSON characters in
  the chat bubble.

  Envelope detection is two-stage:

    1. **Candidacy** — the accumulated text must start (after optional
       markdown fence) with `{` or `[`. Non-JSON prose is ignored.
    2. **Parse** — `Rho.Parse.Lenient.parse_partial/1` auto-closes
       unclosed `{`, `[`, `"` at EOF, then `Jason.decode`s. For a map
       with an `action` (or `tool`/`name`) key we return an envelope
       summary; otherwise `:no_envelope`.

  The summary is intentionally thin: `action_name`, `action_input`
  (which may itself be a partial map), and any `thinking` field. The
  UI decides how to render it.
  """

  @type summary :: %{
          action: String.t() | nil,
          action_input: any(),
          thinking: String.t() | nil
        }

  @type result :: :no_envelope | {:envelope, summary()}

  @doc """
  Analyze an accumulated streaming-text buffer. Returns `:no_envelope`
  if the text doesn't look like a JSON envelope, or `{:envelope, summary}`
  with the extracted action/action_input/thinking fields.
  """
  @spec analyze(String.t()) :: result()
  def analyze(text) when is_binary(text) do
    if envelope_candidate?(text) do
      case Rho.Parse.Lenient.parse_partial(text) do
        {:ok, %{} = map} -> from_map(map) |> or_regex_fallback(text)
        _ -> regex_fallback(text)
      end
    else
      :no_envelope
    end
  end

  @doc "Returns true if the (possibly fenced) text starts with `{` or `[`."
  def envelope_candidate?(text) do
    trimmed = text |> Rho.Parse.Lenient.strip_fences() |> String.trim_leading()
    String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[")
  end

  defp from_map(map) do
    action = map["action"] || map["tool"] || map["tool_name"] || map["name"]
    thinking = map["thinking"] || map["reasoning"]

    action_input =
      map["action_input"] || map["tool_input"] || map["parameters"] || map["args"] ||
        map["arguments"] || map["input"]

    cond do
      is_binary(action) ->
        {:envelope,
         %{
           action: action,
           action_input: normalize_action_input(action_input),
           thinking: thinking
         }}

      # Even without an action yet, if we've got a thinking preamble under
      # structured-reasoner prompting, surface that to the UI.
      is_binary(thinking) ->
        {:envelope, %{action: nil, action_input: nil, thinking: thinking}}

      true ->
        :no_envelope
    end
  end

  # Models often nest JSON inside a string (`action_input: "{\"x\":1}"`).
  # Try to lenient-parse those strings into structured form for display.
  defp normalize_action_input(v) when is_binary(v) do
    case Rho.Parse.Lenient.parse(v) do
      {:ok, decoded} -> decoded
      _ -> v
    end
  end

  defp normalize_action_input(v), do: v

  # If the auto-closed parse didn't find an action but the raw text has a
  # `"action": "name"` pattern, fall back to scraping it with a regex.
  # Useful for deeply-nested partial envelopes where auto_close can't
  # produce valid JSON.
  defp or_regex_fallback(:no_envelope, text), do: regex_fallback(text)
  defp or_regex_fallback(other, _text), do: other

  @action_regex ~r/"(?:action|tool|tool_name|name)"\s*:\s*"([^"]+)"/
  @thinking_regex ~r/"(?:thinking|reasoning)"\s*:\s*"((?:[^"\\]|\\.)*)/

  defp regex_fallback(text) do
    action =
      case Regex.run(@action_regex, text) do
        [_, name] -> name
        _ -> nil
      end

    thinking =
      case Regex.run(@thinking_regex, text) do
        [_, t] -> t
        _ -> nil
      end

    cond do
      is_binary(action) ->
        {:envelope, %{action: action, action_input: nil, thinking: thinking}}

      is_binary(thinking) ->
        {:envelope, %{action: nil, action_input: nil, thinking: thinking}}

      true ->
        :no_envelope
    end
  end
end
