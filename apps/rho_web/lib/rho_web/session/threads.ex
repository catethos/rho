defmodule RhoWeb.Session.Threads do
  @moduledoc """
  Thread registry for conversation branching within a session.

  Persists thread metadata as JSON at
  `_rho/sessions/{session_id}/threads.json`.

  All maps use string keys for clean JSON round-tripping.
  """

  @filename "threads.json"

  # -------------------------------------------------------------------
  # Init
  # -------------------------------------------------------------------

  @doc """
  Initialize the thread registry for a session, creating an implicit
  "Main" thread pointing at `tape_name`.

  No-op if `threads.json` already exists.

  Returns `{:ok, state}` where state is the full registry map.
  """
  @spec init(String.t(), String.t(), keyword()) :: {:ok, map()}
  def init(session_id, workspace, opts \\ []) do
    path = threads_path(session_id, workspace)

    cond do
      conversation = conversation_for(session_id, workspace) ->
        state = state_from_conversation(conversation)
        write_state(path, state)
        {:ok, state}

      File.exists?(path) ->
        {:ok, read_state(path)}

      true ->
        tape_name = Keyword.fetch!(opts, :tape_name)
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        main_thread = %{
          "id" => "thread_main",
          "name" => "Main",
          "tape_name" => tape_name,
          "created_at" => now,
          "forked_from" => nil,
          "fork_point" => nil,
          "summary" => nil,
          "status" => "active"
        }

        state = %{
          "active_thread_id" => "thread_main",
          "threads" => [main_thread]
        }

        write_state(path, state)
        {:ok, state}
    end
  end

  @doc """
  Import an existing `threads.json` registry into core conversation metadata.

  This is the lazy migration path for sessions created before
  `Rho.Conversation` existed. The legacy file is left in place; subsequent
  calls mirror the conversation back into `threads.json` for compatibility.
  """
  @spec import_legacy(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_legacy(session_id, workspace, opts \\ []) do
    path = threads_path(session_id, workspace)

    if File.exists?(path) do
      state = read_state(path)
      default_tape = Keyword.get(opts, :tape_name)
      threads = conversation_threads_from_legacy(state, default_tape)

      active_thread_id =
        case Enum.find(threads, &(&1["id"] == state["active_thread_id"])) do
          %{"id" => id} -> id
          _ -> threads |> List.first() |> Map.fetch!("id")
        end

      Rho.Conversation.create(%{
        session_id: session_id,
        user_id: Keyword.get(opts, :user_id),
        organization_id: Keyword.get(opts, :organization_id),
        workspace: workspace,
        title: Keyword.get(opts, :title, "New conversation"),
        active_thread_id: active_thread_id,
        threads: threads
      })
    else
      {:error, :not_found}
    end
  rescue
    error -> {:error, error}
  end

  # -------------------------------------------------------------------
  # Queries
  # -------------------------------------------------------------------

  @doc "List all threads for a session. Returns `[]` if no registry exists."
  @spec list(String.t(), String.t()) :: [map()]
  def list(session_id, workspace) do
    path = threads_path(session_id, workspace)

    cond do
      conversation = conversation_for(session_id, workspace) ->
        Enum.map(conversation["threads"] || [], &legacy_thread/1)

      File.exists?(path) ->
        read_state(path) |> Map.get("threads", [])

      true ->
        []
    end
  end

  @doc "Return the active thread map, or `nil`."
  @spec active(String.t(), String.t()) :: map() | nil
  def active(session_id, workspace) do
    path = threads_path(session_id, workspace)

    cond do
      conversation = conversation_for(session_id, workspace) ->
        conversation
        |> active_from_conversation()
        |> maybe_legacy_thread()

      File.exists?(path) ->
        state = read_state(path)
        active_id = state["active_thread_id"]
        Enum.find(state["threads"] || [], &(&1["id"] == active_id))

      true ->
        nil
    end
  end

  @doc "Return a single thread by ID, or `nil`."
  @spec get(String.t(), String.t(), String.t()) :: map() | nil
  def get(session_id, workspace, thread_id) do
    path = threads_path(session_id, workspace)

    cond do
      conversation = conversation_for(session_id, workspace) ->
        conversation["threads"]
        |> Enum.find(&(&1["id"] == thread_id))
        |> maybe_legacy_thread()

      File.exists?(path) ->
        state = read_state(path)
        Enum.find(state["threads"] || [], &(&1["id"] == thread_id))

      true ->
        nil
    end
  end

  # -------------------------------------------------------------------
  # Fork
  # -------------------------------------------------------------------

  @doc """
  Fork a new thread from the current active thread.

  1. Checks `needs_summary?/2` to decide if compaction is needed.
  2. Calls `tape_module.fork(current_tape, at: fork_point)` to create a fork tape.
  3. Registers the new thread via `create/3`.
  4. Switches to the new thread via `switch/3`.

  Returns `{:ok, thread}` or `{:error, reason}`.

  ## Options
    * `:name` — thread name (default: "Fork of <parent>")
    * `:fork_point` — tape entry ID to fork at (default: latest)
  """
  @spec fork_thread(String.t(), String.t(), module(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def fork_thread(session_id, workspace, tape_module, opts \\ []) do
    case active(session_id, workspace) do
      nil ->
        {:error, :no_registry}

      parent ->
        parent_tape = parent["tape_name"]
        fork_point = Keyword.get(opts, :fork_point)
        name = Keyword.get(opts, :name, "Fork of #{parent["name"]}")

        # Decide whether to summarize before forking
        summary =
          if needs_summary?(parent_tape, fork_point) do
            summarize_up_to(parent_tape, tape_module, fork_point)
          else
            nil
          end

        # Create the fork tape via the tape module
        fork_opts = if fork_point, do: [at: fork_point], else: []
        {:ok, fork_tape_name} = tape_module.fork(parent_tape, fork_opts)

        # Register and switch to the new thread
        {:ok, thread} =
          create(session_id, workspace, %{
            "name" => name,
            "tape_name" => fork_tape_name,
            "forked_from" => parent["id"],
            "fork_point" => fork_point,
            "summary" => summary
          })

        :ok = switch(session_id, workspace, thread["id"])
        {:ok, thread}
    end
  end

  @doc """
  Determines whether the tape history before `fork_point` is long enough
  to warrant a compaction summary.

  Returns `false` (skip summary) when:
  - The tape has 5 or fewer entries
  - There's a recent anchor within 3 entries of the fork point

  Returns `true` otherwise.
  """
  @spec needs_summary?(String.t(), non_neg_integer() | nil) :: boolean()
  def needs_summary?(tape_name, fork_point) do
    alias Rho.Tape.Store

    total = Store.last_id(tape_name)

    # Skip for very short tapes
    if total <= 5 do
      false
    else
      # Check if there's a recent anchor near the fork point
      point = fork_point || total

      case Store.last_anchor(tape_name) do
        %{id: anchor_id} when point - anchor_id <= 3 ->
          false

        _ ->
          true
      end
    end
  end

  @doc """
  Stub: LLM-based summarization of tape history up to a given point.

  Will eventually call the LLM to produce a summary of the conversation
  before the fork point, for use as a fork anchor. Currently returns nil.
  """
  @spec summarize_up_to(String.t(), module(), non_neg_integer() | nil) :: String.t() | nil
  def summarize_up_to(_tape_name, _tape_module, _fork_point) do
    # Deferred: LLM summarization call
    nil
  end

  # -------------------------------------------------------------------
  # Mutations
  # -------------------------------------------------------------------

  @doc """
  Create a new thread. `attrs` must include `"name"` and `"tape_name"`.

  Optional keys: `"forked_from"`, `"fork_point"`, `"summary"`.

  Returns `{:ok, thread}` or `{:error, :no_registry}`.
  """
  @spec create(String.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def create(session_id, workspace, attrs) do
    path = threads_path(session_id, workspace)

    cond do
      conversation = conversation_for(session_id, workspace) ->
        attrs = Map.put_new(attrs, "fork_point_entry_id", Map.get(attrs, "fork_point"))

        case Rho.Conversation.create_thread(conversation["id"], attrs) do
          {:ok, thread} ->
            mirror_conversation(session_id, workspace)
            {:ok, legacy_thread(thread)}

          {:error, reason} ->
            {:error, reason}
        end

      File.exists?(path) ->
        state = read_state(path)
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        thread = %{
          "id" => generate_id(),
          "name" => Map.fetch!(attrs, "name"),
          "tape_name" => Map.fetch!(attrs, "tape_name"),
          "created_at" => now,
          "forked_from" => Map.get(attrs, "forked_from"),
          "fork_point" => Map.get(attrs, "fork_point"),
          "summary" => Map.get(attrs, "summary"),
          "status" => "active"
        }

        state = Map.update!(state, "threads", &(&1 ++ [thread]))
        write_state(path, state)
        {:ok, thread}

      true ->
        {:error, :no_registry}
    end
  end

  @doc """
  Switch the active thread. Returns `:ok` or `{:error, :not_found}`.
  """
  @spec switch(String.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def switch(session_id, workspace, thread_id) do
    path = threads_path(session_id, workspace)

    cond do
      conversation = conversation_for(session_id, workspace) ->
        case Rho.Conversation.switch_thread(conversation["id"], thread_id) do
          :ok ->
            mirror_conversation(session_id, workspace)
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      File.exists?(path) ->
        state = read_state(path)

        if Enum.any?(state["threads"] || [], &(&1["id"] == thread_id)) do
          state = Map.put(state, "active_thread_id", thread_id)
          write_state(path, state)
          :ok
        else
          {:error, :not_found}
        end

      true ->
        {:error, :not_found}
    end
  end

  @doc """
  Delete a thread. Cannot delete the currently active thread.

  Returns `:ok`, `{:error, :active_thread}`, or `{:error, :not_found}`.
  """
  @spec delete(String.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def delete(session_id, workspace, thread_id) do
    path = threads_path(session_id, workspace)

    cond do
      conversation = conversation_for(session_id, workspace) ->
        case Rho.Conversation.delete_thread(conversation["id"], thread_id) do
          :ok ->
            mirror_conversation(session_id, workspace)
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      File.exists?(path) ->
        state = read_state(path)

        cond do
          state["active_thread_id"] == thread_id ->
            {:error, :active_thread}

          Enum.any?(state["threads"] || [], &(&1["id"] == thread_id)) ->
            threads = Enum.reject(state["threads"], &(&1["id"] == thread_id))
            write_state(path, Map.put(state, "threads", threads))
            :ok

          true ->
            {:error, :not_found}
        end

      true ->
        {:error, :not_found}
    end
  end

  # -------------------------------------------------------------------
  # Internals
  # -------------------------------------------------------------------

  defp threads_path(session_id, workspace) do
    Path.join([workspace, "_rho", "sessions", session_id, @filename])
  end

  defp read_state(path) do
    path |> File.read!() |> Jason.decode!()
  end

  defp write_state(path, state) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(state, pretty: true))
    File.rename!(tmp, path)
  end

  defp conversation_for(session_id, workspace) do
    case Rho.Conversation.get_by_session(session_id) do
      %{"workspace" => ^workspace} = conversation -> conversation
      _ -> nil
    end
  end

  defp mirror_conversation(session_id, workspace) do
    if conversation = conversation_for(session_id, workspace) do
      write_state(threads_path(session_id, workspace), state_from_conversation(conversation))
    end
  end

  defp conversation_threads_from_legacy(state, default_tape) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case state["threads"] || [] do
      [] ->
        [
          %{
            "id" => "thread_main",
            "name" => "Main",
            "tape_name" => default_tape,
            "forked_from" => nil,
            "fork_point_entry_id" => nil,
            "summary" => nil,
            "created_at" => now,
            "updated_at" => now,
            "status" => "active"
          }
        ]

      threads ->
        Enum.map(threads, &conversation_thread_from_legacy(&1, default_tape, now))
    end
  end

  defp conversation_thread_from_legacy(thread, default_tape, now) do
    %{
      "id" => thread["id"] || generate_id(),
      "name" => thread["name"] || "New Thread",
      "tape_name" => thread["tape_name"] || default_tape,
      "forked_from" => thread["forked_from"],
      "fork_point_entry_id" => thread["fork_point_entry_id"] || thread["fork_point"],
      "summary" => thread["summary"],
      "created_at" => thread["created_at"] || now,
      "updated_at" => thread["updated_at"] || thread["created_at"] || now,
      "status" => thread["status"] || "active"
    }
  end

  defp state_from_conversation(conversation) do
    %{
      "active_thread_id" => conversation["active_thread_id"],
      "threads" => Enum.map(conversation["threads"] || [], &legacy_thread/1)
    }
  end

  defp active_from_conversation(conversation) do
    Enum.find(conversation["threads"] || [], &(&1["id"] == conversation["active_thread_id"]))
  end

  defp maybe_legacy_thread(nil), do: nil
  defp maybe_legacy_thread(thread), do: legacy_thread(thread)

  defp legacy_thread(thread) do
    thread
    |> Map.put_new("fork_point", thread["fork_point_entry_id"])
    |> Map.put("fork_point", thread["fork_point"] || thread["fork_point_entry_id"])
  end

  defp generate_id do
    "thread_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
