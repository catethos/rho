defmodule RhoWeb.StreamEnvelope do
  @moduledoc """
  Detects and decodes JSON-envelope shapes in streaming assistant text
  from `Rho.TurnStrategy.TypedStructured`. Used to render a human-readable
  preview of a tool/action dispatch while the model is still mid-stream,
  instead of showing raw escaped JSON characters in the chat bubble.

  Envelope detection is two-stage:

    1. **Candidacy** — the accumulated text must start (after optional
       markdown fence) with `{` or `[`. Non-JSON prose is ignored.
    2. **Parse** — `Rho.StructuredOutput.parse_partial/1` uses multiple
       completion strategies (close-as-is, null for trailing colon,
       strip trailing comma, truncate to last comma) to handle
       incomplete streaming JSON. For a map with a `tool` key we return
       an envelope summary; otherwise `:no_envelope`.

  The summary is intentionally thin: `action` (the tool name), `message`
  (for respond), and any `thinking` field. The UI decides how to render it.
  """

  @type summary :: %{
          action: String.t() | nil,
          message: String.t() | nil,
          thinking: String.t() | nil
        }

  @type result :: :no_envelope | {:envelope, summary()}

  @doc """
  Analyze an accumulated streaming-text buffer. Returns `:no_envelope`
  if the text doesn't look like a JSON envelope, or `{:envelope, summary}`
  with the extracted fields.
  """
  @spec analyze(String.t()) :: result()
  def analyze(text) when is_binary(text) do
    if envelope_candidate?(text) do
      stripped = Rho.Parse.Lenient.strip_fences(text)

      case Rho.StructuredOutput.parse_partial(stripped) do
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
    action = map["tool"] || map["action"] || map["tool_name"] || map["name"]
    thinking = map["thinking"] || map["reasoning"] || map["thought"]
    message = map["message"]

    cond do
      is_binary(action) ->
        {:envelope, %{action: action, message: message, thinking: thinking}}

      is_binary(thinking) ->
        {:envelope, %{action: nil, message: nil, thinking: thinking}}

      true ->
        :no_envelope
    end
  end

  defp or_regex_fallback(:no_envelope, text), do: regex_fallback(text)
  defp or_regex_fallback(other, _text), do: other

  @action_regex ~r/"(?:tool|action|tool_name|name)"\s*:\s*"([^"]+)"/
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
        {:envelope, %{action: action, message: nil, thinking: thinking}}

      is_binary(thinking) ->
        {:envelope, %{action: nil, message: nil, thinking: thinking}}

      true ->
        :no_envelope
    end
  end
end
