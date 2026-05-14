defmodule Rho.Conversation.Index do
  @moduledoc """
  File-backed conversation metadata storage.

  The index is deliberately small and JSON-only so the core runtime stays
  independent of Phoenix and Ecto. Conversation files contain thread metadata;
  message history remains in tapes.
  """

  @index_file "index.json"

  @doc "Return the conversations directory under `Rho.Paths.data_dir/0`."
  @spec conversations_dir() :: String.t()
  def conversations_dir, do: Path.join(Rho.Paths.data_dir(), "conversations")

  @doc "Return the path for the conversation index JSON file."
  @spec index_path() :: String.t()
  def index_path, do: Path.join(conversations_dir(), @index_file)

  @doc "Load the conversation index, returning an empty index if absent."
  @spec load_index() :: map()
  def load_index do
    case File.read(index_path()) do
      {:ok, json} ->
        json
        |> Jason.decode!()
        |> normalize_index()

      {:error, :enoent} ->
        empty_index()

      {:error, _reason} ->
        empty_index()
    end
  rescue
    _ -> empty_index()
  end

  @doc "Atomically write the conversation index."
  @spec write_index(map()) :: :ok
  def write_index(index) when is_map(index) do
    write_json_atomic(index_path(), normalize_index(index))
  end

  @doc "Return the JSON file path for a conversation id."
  @spec conversation_path(String.t()) :: String.t()
  def conversation_path(conversation_id) when is_binary(conversation_id) do
    Path.join(conversations_dir(), "#{conversation_id}.json")
  end

  @doc "Read a conversation metadata file."
  @spec read_conversation(String.t()) :: {:ok, map()} | {:error, term()}
  def read_conversation(conversation_id) when is_binary(conversation_id) do
    path = conversation_path(conversation_id)

    with {:ok, json} <- File.read(path),
         {:ok, data} <- Jason.decode(json) do
      {:ok, normalize_conversation(data)}
    end
  end

  @doc "Atomically write a conversation metadata file and update the index."
  @spec write_conversation(map()) :: :ok
  def write_conversation(%{"id" => id} = conversation) when is_binary(id) do
    conversation = normalize_conversation(conversation)
    write_json_atomic(conversation_path(id), conversation)
    upsert_index_entry(conversation)
  end

  def write_conversation(%{} = conversation) do
    conversation
    |> stringify_keys()
    |> write_conversation()
  end

  @doc "Return true when a conversation metadata file exists."
  @spec exists?(String.t()) :: boolean()
  def exists?(conversation_id), do: File.exists?(conversation_path(conversation_id))

  @doc "Normalize conversation maps loaded from JSON or callers."
  @spec normalize_conversation(map()) :: map()
  def normalize_conversation(conversation) when is_map(conversation) do
    conversation = stringify_keys(conversation)
    threads = Enum.map(conversation["threads"] || [], &Rho.Conversation.Thread.normalize/1)

    conversation
    |> Map.put("threads", threads)
    |> Map.put_new("archived_at", nil)
    |> Map.put_new("agent_name", "default")
    |> Map.put_new("position", nil)
  end

  @doc "Return a position value that places a new conversation at the top of its scope."
  @spec next_position(map()) :: integer()
  def next_position(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    user_id = stringify_nullable(attrs["user_id"])
    organization_id = stringify_nullable(attrs["organization_id"])

    positions =
      index_entries()
      |> Enum.filter(fn entry ->
        stringify_nullable(entry["user_id"]) == user_id and
          stringify_nullable(entry["organization_id"]) == organization_id and
          is_nil(entry["archived_at"])
      end)
      |> Enum.flat_map(fn entry ->
        case numeric_position(entry["position"]) do
          nil -> []
          position -> [position]
        end
      end)

    case positions do
      [] -> 0
      _ -> Enum.min(positions) - 1000
    end
  end

  @doc "Return all indexed entries."
  @spec index_entries() :: [map()]
  def index_entries do
    load_index()["conversations"]
  end

  defp upsert_index_entry(conversation) do
    index = load_index()
    entry = index_entry(conversation)
    entry_id = entry["id"]

    current = index["conversations"] || []

    entries =
      if Enum.any?(current, &(&1["id"] == entry_id)) do
        Enum.map(current, fn
          %{"id" => id} when id == entry_id -> entry
          other -> other
        end)
      else
        current ++ [entry]
      end
      |> sort_index_entries()

    write_index(%{"conversations" => entries})
  end

  defp index_entry(conversation) do
    Map.take(conversation, [
      "id",
      "session_id",
      "user_id",
      "organization_id",
      "agent_name",
      "title",
      "position",
      "active_thread_id",
      "created_at",
      "updated_at",
      "archived_at"
    ])
  end

  defp sort_index_entries(entries) do
    entries
    |> Enum.with_index()
    |> Enum.sort_by(fn {entry, index} ->
      case numeric_position(entry["position"]) do
        nil -> {1, index}
        position -> {0, position}
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp numeric_position(position) when is_integer(position), do: position

  defp numeric_position(position) when is_float(position), do: round(position)

  defp numeric_position(position) when is_binary(position) do
    case Integer.parse(position) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp numeric_position(_position), do: nil

  defp normalize_index(index) when is_map(index) do
    %{"conversations" => Enum.map(index["conversations"] || [], &stringify_keys/1)}
  end

  defp empty_index, do: %{"conversations" => []}

  defp write_json_atomic(path, data) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(data, pretty: true))
    File.rename!(tmp, path)
    :ok
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} -> {key, stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp stringify_nullable(nil), do: nil
  defp stringify_nullable(value), do: to_string(value)
end
