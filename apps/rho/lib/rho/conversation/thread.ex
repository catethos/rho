defmodule Rho.Conversation.Thread do
  @moduledoc """
  Helpers for durable conversation thread metadata.

  Threads are metadata over tapes. They do not contain messages.
  """

  @doc "Build a JSON-safe thread metadata map."
  @spec new(map(), keyword()) :: map()
  def new(attrs, opts \\ []) when is_map(attrs) do
    now = Keyword.get(opts, :now) || now()

    %{
      "id" => get_attr(attrs, "id") || generate_id(),
      "name" => get_attr(attrs, "name") || "New Thread",
      "tape_name" => get_attr(attrs, "tape_name"),
      "forked_from" => get_attr(attrs, "forked_from"),
      "fork_point_entry_id" =>
        get_attr(attrs, "fork_point_entry_id") || get_attr(attrs, "fork_point"),
      "summary" => get_attr(attrs, "summary"),
      "created_at" => get_attr(attrs, "created_at") || now,
      "updated_at" => get_attr(attrs, "updated_at") || now,
      "status" => get_attr(attrs, "status") || "active"
    }
  end

  @doc "Normalize legacy thread maps to the current persisted shape."
  @spec normalize(map()) :: map()
  def normalize(thread) when is_map(thread) do
    thread
    |> stringify_keys()
    |> then(fn t ->
      t
      |> Map.put_new("fork_point_entry_id", t["fork_point"])
      |> Map.put_new("updated_at", t["created_at"] || now())
      |> Map.put_new("status", "active")
    end)
  end

  defp get_attr(map, key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp generate_id do
    "thread_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
