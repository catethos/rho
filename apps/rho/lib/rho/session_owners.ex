defmodule Rho.SessionOwners do
  @moduledoc """
  Persistent `(session_id → user_id)` ownership map.

  A session_id is freely passed around in URLs and PubSub topics.
  Without an ownership check, any authenticated user who knows another
  user's session_id can resume their agent or subscribe to their event
  stream. This module is the gate.

  ## Semantics

    * `register/2` — first writer wins; second registration with a
      different user_id returns `{:error, :already_owned}`.
    * `authorize/2` — passes when the caller's user_id matches the
      recorded owner. If the session has no owner yet, registers it
      (TOFU). `nil` user_id is treated as system context (CLI, mix
      tasks) and bypasses the check.

  ## Persistence

  Backed by ETS (`:rho_session_owners`) for read speed, persisted to
  `Rho.Paths.session_owners_path/0` as append-only JSONL. The file is
  reloaded on `init/1`.
  """

  use GenServer

  @table :rho_session_owners

  # ---- Public API ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record that `user_id` owns `session_id`. Idempotent for matching owner."
  @spec register(String.t(), Rho.Paths.user_id()) :: :ok | {:error, :already_owned}
  def register(session_id, user_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:register, session_id, normalize(user_id)})
  end

  @doc "Look up the owner of `session_id`. Returns `{:ok, user_id}` or `:not_found`."
  @spec owner(String.t()) :: {:ok, Rho.Paths.user_id()} | :not_found
  def owner(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, user_id}] -> {:ok, user_id}
      [] -> :not_found
    end
  end

  @doc """
  Authorize `user_id` to access `session_id`.

    * `:ok` — caller owns the session, or session is unowned (registers
      the caller as owner).
    * `:ok` — `user_id` is `nil` (system / CLI context, no enforcement).
    * `{:error, :forbidden}` — owner mismatch.
  """
  @spec authorize(String.t(), Rho.Paths.user_id()) :: :ok | {:error, :forbidden}
  def authorize(_session_id, nil), do: :ok

  def authorize(session_id, user_id) when is_binary(session_id) do
    user_id = normalize(user_id)

    case owner(session_id) do
      {:ok, ^user_id} ->
        :ok

      {:ok, _other} ->
        {:error, :forbidden}

      :not_found ->
        case register(session_id, user_id) do
          :ok ->
            :ok

          # Race: another caller registered first. Re-check.
          {:error, :already_owned} ->
            case owner(session_id) do
              {:ok, ^user_id} -> :ok
              _ -> {:error, :forbidden}
            end
        end
    end
  end

  # ---- GenServer callbacks ----

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    File.mkdir_p!(Path.dirname(Rho.Paths.session_owners_path()))
    load_from_disk()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, session_id, user_id}, _from, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, ^user_id}] ->
        {:reply, :ok, state}

      [{^session_id, _other}] ->
        {:reply, {:error, :already_owned}, state}

      [] ->
        :ets.insert(@table, {session_id, user_id})
        append_to_disk(session_id, user_id)
        {:reply, :ok, state}
    end
  end

  # ---- Private ----

  defp load_from_disk do
    path = Rho.Paths.session_owners_path()

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.each(fn line ->
        case Jason.decode(line) do
          {:ok, %{"sid" => sid, "uid" => uid}} ->
            :ets.insert(@table, {sid, normalize(uid)})

          _ ->
            :ok
        end
      end)
    end
  end

  defp append_to_disk(session_id, user_id) do
    path = Rho.Paths.session_owners_path()
    line = Jason.encode!(%{sid: session_id, uid: user_id}) <> "\n"
    File.write!(path, line, [:append])
  end

  # Normalize user_id storage so integer 42 and string "42" don't both
  # claim the same session under different keys.
  defp normalize(nil), do: nil
  defp normalize(id) when is_binary(id), do: id
  defp normalize(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize(id), do: to_string(id)
end
