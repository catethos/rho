defmodule ReqLLM.Providers.FireworksAI do
  @moduledoc """
  Fireworks AI provider – OpenAI-compatible Chat Completions API.

  ## Configuration

      # Add to .env file
      FIREWORKS_API_KEY=fw_...

  ## Usage

      ReqLLM.generate_text("fireworks_ai:accounts/fireworks/models/deepseek-v3p1", "Hello!")
  """

  use ReqLLM.Provider,
    id: :fireworks_ai,
    default_base_url: "https://api.fireworks.ai/inference/v1",
    default_env_key: "FIREWORKS_API_KEY"

  use ReqLLM.Provider.Defaults

  @impl true
  def build_body(request) do
    # Fireworks doesn't support cache_control on content parts.
    # Strip it from message structs so the default encoder collapses
    # single-text arrays to plain strings.
    request
    |> strip_cache_control_from_messages()
    |> super()
  end

  defp strip_cache_control_from_messages(request) do
    case request.options[:context] do
      %ReqLLM.Context{messages: msgs} = ctx ->
        cleaned = Enum.map(msgs, &strip_cache_control/1)
        put_in(request.options[:context], %{ctx | messages: cleaned})

      _ ->
        msgs = request.options[:messages] || []
        cleaned = Enum.map(msgs, &strip_cache_control/1)
        put_in(request.options[:messages], cleaned)
    end
  end

  defp strip_cache_control(%{content: parts} = msg) when is_list(parts) do
    %{msg | content: Enum.map(parts, &drop_cache_control_metadata/1)}
  end

  defp strip_cache_control(msg), do: msg

  defp drop_cache_control_metadata(%{metadata: meta} = part) when is_map(meta) do
    %{part | metadata: Map.delete(meta, :cache_control)}
  end

  defp drop_cache_control_metadata(part), do: part
end
