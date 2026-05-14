defmodule Rho.Conversation do
  @moduledoc """
  Durable conversation and thread metadata.

  A conversation is a user-facing container. Its threads point to tapes, and
  the tapes remain the source of truth for messages and agent trace facts.
  """

  alias Rho.Conversation.{Index, Thread}

  @doc "Create a conversation metadata record."
  @spec create(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def create(attrs) when is_list(attrs), do: attrs |> Map.new() |> create()

  def create(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    now = now()
    id = attrs["id"] || generate_id()

    threads =
      case attrs["threads"] do
        [_ | _] = threads -> Enum.map(threads, &Thread.normalize/1)
        _ -> [main_thread(attrs, now)]
      end

    active_thread_id =
      attrs["active_thread_id"] ||
        threads |> List.first() |> then(&(&1 && &1["id"])) ||
        "thread_main"

    conversation = %{
      "id" => id,
      "session_id" => attrs["session_id"],
      "user_id" => stringify_nullable(attrs["user_id"]),
      "organization_id" => stringify_nullable(attrs["organization_id"]),
      "workspace" => attrs["workspace"],
      "agent_name" => stringify_nullable(attrs["agent_name"] || attrs["agent"] || :default),
      "title" => attrs["title"] || "New conversation",
      "position" => attrs["position"] || Index.next_position(attrs),
      "active_thread_id" => active_thread_id,
      "created_at" => attrs["created_at"] || now,
      "updated_at" => attrs["updated_at"] || now,
      "archived_at" => attrs["archived_at"],
      "threads" => threads
    }

    Index.write_conversation(conversation)
    {:ok, conversation}
  rescue
    error -> {:error, error}
  end

  @doc "Get a conversation by id."
  @spec get(String.t()) :: map() | nil
  def get(conversation_id) when is_binary(conversation_id) do
    case Index.read_conversation(conversation_id) do
      {:ok, conversation} -> conversation
      {:error, _} -> nil
    end
  end

  @doc """
  Get a conversation by session id.

  Optional `:user_id`, `:organization_id`, and `:workspace` filters constrain
  the lookup for user-facing resume paths. Calling with no filters preserves the
  internal/debug behavior of resolving by session id alone.
  """
  @spec get_by_session(String.t(), keyword()) :: map() | nil
  def get_by_session(session_id, opts \\ []) when is_binary(session_id) do
    workspace = Keyword.get(opts, :workspace)

    list(
      include_archived: true,
      user_id: Keyword.get(opts, :user_id),
      organization_id: Keyword.get(opts, :organization_id)
    )
    |> filter_workspace(workspace)
    |> Enum.find(&(&1["session_id"] == session_id))
  end

  @doc "List conversations, optionally filtered by `:user_id` and `:organization_id`."
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    include_archived? = Keyword.get(opts, :include_archived, false)
    user_id = opts |> Keyword.get(:user_id) |> stringify_nullable()
    organization_id = opts |> Keyword.get(:organization_id) |> stringify_nullable()

    Index.index_entries()
    |> Enum.reject(fn entry -> not include_archived? and not is_nil(entry["archived_at"]) end)
    |> filter_eq("user_id", user_id)
    |> filter_eq("organization_id", organization_id)
    |> Enum.flat_map(fn %{"id" => id} ->
      case get(id) do
        nil -> []
        conversation -> [conversation]
      end
    end)
  end

  @doc "Archive a conversation."
  @spec archive(String.t()) :: {:ok, map()} | {:error, term()}
  def archive(conversation_id) do
    update_conversation(conversation_id, fn conversation ->
      now = now()

      conversation
      |> Map.put("archived_at", now)
      |> Map.put("updated_at", now)
    end)
  end

  @doc "Update a conversation's `updated_at` timestamp."
  @spec touch(String.t()) :: {:ok, map()} | {:error, term()}
  def touch(conversation_id) do
    update_conversation(conversation_id, &Map.put(&1, "updated_at", now()))
  end

  @doc "Persist a user-facing conversation title."
  @spec set_title(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_title(conversation_id, title) when is_binary(title) do
    title =
      title
      |> String.trim()
      |> truncate(80)
      |> case do
        "" -> "New conversation"
        value -> value
      end

    update_conversation(conversation_id, &Map.put(&1, "title", title))
  end

  @doc "Persist the user-defined order for conversations."
  @spec reorder([String.t()]) :: :ok | {:error, term()}
  def reorder(conversation_ids) when is_list(conversation_ids) do
    conversation_ids
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {conversation_id, index}, :ok ->
      case set_position(conversation_id, index * 1000) do
        {:ok, _conversation} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Persist the agent config name associated with a conversation."
  @spec set_agent_name(String.t(), atom() | String.t()) :: {:ok, map()} | {:error, term()}
  def set_agent_name(conversation_id, agent_name) do
    update_conversation(conversation_id, fn conversation ->
      conversation
      |> Map.put("agent_name", stringify_nullable(agent_name || :default))
      |> Map.put("updated_at", now())
    end)
  end

  @doc "Persist a sortable conversation position."
  @spec set_position(String.t(), integer()) :: {:ok, map()} | {:error, term()}
  def set_position(conversation_id, position) when is_integer(position) do
    update_conversation(conversation_id, &Map.put(&1, "position", position))
  end

  @doc "Create a named thread under a conversation."
  @spec create_thread(String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def create_thread(conversation_id, attrs) when is_list(attrs),
    do: create_thread(conversation_id, Map.new(attrs))

  def create_thread(conversation_id, attrs) when is_map(attrs) do
    with {:ok, conversation} <- fetch(conversation_id) do
      now = now()
      thread = Thread.new(attrs, now: now)

      conversation =
        conversation
        |> Map.update!("threads", &(&1 ++ [thread]))
        |> Map.put("updated_at", now)

      Index.write_conversation(conversation)
      {:ok, thread}
    end
  end

  @doc "List threads for a conversation."
  @spec list_threads(String.t()) :: [map()]
  def list_threads(conversation_id) do
    case get(conversation_id) do
      nil -> []
      conversation -> conversation["threads"] || []
    end
  end

  @doc "Get a thread by id."
  @spec get_thread(String.t(), String.t()) :: map() | nil
  def get_thread(conversation_id, thread_id) do
    conversation_id
    |> list_threads()
    |> Enum.find(&(&1["id"] == thread_id))
  end

  @doc "Return the active thread for a conversation."
  @spec active_thread(String.t()) :: map() | nil
  def active_thread(conversation_id) do
    with %{} = conversation <- get(conversation_id) do
      get_thread(conversation_id, conversation["active_thread_id"])
    end
  end

  @doc "Switch the active thread."
  @spec switch_thread(String.t(), String.t()) :: :ok | {:error, term()}
  def switch_thread(conversation_id, thread_id) do
    with {:ok, conversation} <- fetch(conversation_id),
         %{} <-
           Enum.find(conversation["threads"], &(&1["id"] == thread_id)) || {:error, :not_found} do
      now = now()

      conversation
      |> Map.put("active_thread_id", thread_id)
      |> Map.put("updated_at", now)
      |> Index.write_conversation()

      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Delete an inactive thread."
  @spec delete_thread(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_thread(conversation_id, thread_id) do
    with {:ok, conversation} <- fetch(conversation_id) do
      cond do
        conversation["active_thread_id"] == thread_id ->
          {:error, :active_thread}

        Enum.any?(conversation["threads"], &(&1["id"] == thread_id)) ->
          conversation
          |> Map.update!("threads", &Enum.reject(&1, fn thread -> thread["id"] == thread_id end))
          |> Map.put("updated_at", now())
          |> Index.write_conversation()

          :ok

        true ->
          {:error, :not_found}
      end
    end
  end

  @doc "Find the conversation that owns `thread_id`."
  @spec get_by_thread(String.t()) :: {map(), map()} | nil
  def get_by_thread(thread_id) when is_binary(thread_id) do
    list(include_archived: true)
    |> Enum.find_value(fn conversation ->
      case Enum.find(conversation["threads"] || [], &(&1["id"] == thread_id)) do
        nil -> nil
        thread -> {conversation, thread}
      end
    end)
  end

  defp fetch(conversation_id) do
    case get(conversation_id) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  defp update_conversation(conversation_id, fun) do
    with {:ok, conversation} <- fetch(conversation_id) do
      conversation = fun.(conversation)
      Index.write_conversation(conversation)
      {:ok, conversation}
    end
  end

  defp main_thread(attrs, now) do
    %{
      "id" => attrs["thread_id"] || "thread_main",
      "name" => attrs["thread_name"] || "Main",
      "tape_name" => attrs["tape_name"],
      "forked_from" => nil,
      "fork_point_entry_id" => nil,
      "summary" => nil,
      "created_at" => now,
      "updated_at" => now,
      "status" => "active"
    }
  end

  defp filter_eq(entries, _key, nil), do: entries

  defp filter_eq(entries, key, value) do
    Enum.filter(entries, &(stringify_nullable(&1[key]) == value))
  end

  defp filter_workspace(entries, nil), do: entries

  defp filter_workspace(entries, workspace),
    do: Enum.filter(entries, &(&1["workspace"] == workspace))

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp stringify_nullable(nil), do: nil
  defp stringify_nullable(value), do: to_string(value)

  defp generate_id do
    "conv_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp truncate(text, max_value) when byte_size(text) <= max_value, do: text

  defp truncate(text, max_value) do
    text
    |> String.slice(0, max_value)
    |> String.trim()
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end