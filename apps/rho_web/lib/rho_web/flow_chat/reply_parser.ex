defmodule RhoWeb.FlowChat.ReplyParser do
  @moduledoc """
  Rule-based, current-step-only parser for chat-native flow replies.
  """

  alias RhoWeb.FlowChat.Message

  @spec parse_action(Message.t(), String.t()) :: {:ok, map()} | {:error, :unknown_action}
  def parse_action(%Message{actions: actions}, action_id) when is_binary(action_id) do
    case Enum.find(actions, &(&1.id == action_id)) do
      nil -> {:error, :unknown_action}
      action -> {:ok, %{action_id: action.id, payload: action.payload, event: action.event}}
    end
  end

  @spec parse_reply(Message.t(), String.t()) :: {:ok, map()} | {:error, :unrecognized_reply}
  def parse_reply(%Message{} = message, text) when is_binary(text) do
    normalized = normalize(text)

    with :error <- parse_by_action(message, normalized),
         :error <- parse_by_node(message, normalized) do
      {:error, :unrecognized_reply}
    end
  end

  defp parse_by_action(%Message{actions: actions}, normalized) do
    Enum.find_value(actions, :error, fn action ->
      labels = [action.id, action.label | payload_values(action.payload)]

      if Enum.any?(labels, &matches?(normalized, &1)) do
        {:ok, %{action_id: action.id, payload: action.payload, event: action.event}}
      end
    end)
  end

  defp parse_by_node(%Message{node_id: :role_transform, actions: actions}, normalized) do
    cond do
      contains_any?(normalized, ["clone", "copy", "exact", "surgical"]) ->
        action_result(actions, "clone")

      contains_any?(normalized, ["inspire", "inspiration", "seed", "reference", "draw from"]) ->
        action_result(actions, "inspire")

      true ->
        :error
    end
  end

  defp parse_by_node(%Message{node_id: :choose_starting_point, actions: actions}, normalized) do
    cond do
      contains_any?(normalized, ["similar role", "template", "role"]) ->
        action_result(actions, "from_template")

      contains_any?(normalized, ["scratch", "new", "blank"]) ->
        action_result(actions, "scratch")

      contains_any?(normalized, ["extend", "existing"]) ->
        action_result(actions, "extend_existing")

      contains_any?(normalized, ["merge", "combine", "two"]) ->
        action_result(actions, "merge")

      true ->
        :error
    end
  end

  defp parse_by_node(%Message{node_id: :taxonomy_preferences, fields: fields}, normalized) do
    taxonomy_size =
      cond do
        contains_any?(normalized, ["compact", "small", "short"]) -> "compact"
        contains_any?(normalized, ["balanced", "medium", "default"]) -> "balanced"
        contains_any?(normalized, ["comprehensive", "large", "detailed"]) -> "comprehensive"
        true -> nil
      end

    if taxonomy_size do
      defaults =
        fields
        |> Enum.map(fn field -> {field.name, field.value} end)
        |> Map.new()

      {:ok,
       %{
         action_id: "taxonomy_preferences",
         event: :submit_form,
         payload: Map.put(defaults, :taxonomy_size, taxonomy_size)
       }}
    else
      :error
    end
  end

  defp parse_by_node(%Message{actions: actions}, normalized) do
    if contains_any?(normalized, [
         "continue",
         "done",
         "looks good",
         "go ahead",
         "generate",
         "save"
       ]) do
      Enum.find_value(actions, :error, fn action ->
        if action.event in [:continue, :confirm_manual, :confirm_selection, :run_action] do
          {:ok, %{action_id: action.id, payload: action.payload, event: action.event}}
        end
      end)
    else
      :error
    end
  end

  defp action_result(actions, id) do
    case Enum.find(actions, &(&1.id == id)) do
      nil -> :error
      action -> {:ok, %{action_id: action.id, payload: action.payload, event: action.event}}
    end
  end

  defp payload_values(payload) when is_map(payload) do
    payload
    |> Enum.flat_map(fn
      {_key, value} when is_binary(value) -> [value]
      _pair -> []
    end)
  end

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s_]+/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp matches?(_normalized, nil), do: false
  defp matches?(normalized, label) when is_binary(label), do: contains_any?(normalized, [label])

  defp contains_any?(normalized, needles) do
    Enum.any?(needles, fn needle ->
      normalized_needle = normalize(to_string(needle))
      normalized_needle != "" and String.contains?(normalized, normalized_needle)
    end)
  end
end
