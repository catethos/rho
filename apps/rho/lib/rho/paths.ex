defmodule Rho.Paths do
  @moduledoc """
  Single source of truth for filesystem paths the runtime persists to.

  All paths root at `data_dir/0`, which defaults to `~/.rho` and can be
  overridden with the `RHO_DATA_DIR` env var (used in production to
  point at a persistent volume mount).

  Per-user paths take a `user_id`. When `user_id` is `nil` (CLI / mix
  tasks / boot before any user logs in), they fall back to a shared
  `_anon` namespace — fine for single-user dev but not for multi-tenant
  use, so callers should pass `user_id` whenever they have one.
  """

  @doc "Root data directory. Override with `RHO_DATA_DIR`."
  @spec data_dir() :: String.t()
  def data_dir do
    case System.get_env("RHO_DATA_DIR") do
      nil -> Path.expand("~/.rho")
      "" -> Path.expand("~/.rho")
      dir -> Path.expand(dir)
    end
  end

  @doc "Tape JSONL directory (`<data_dir>/tapes`)."
  @spec tapes_dir() :: String.t()
  def tapes_dir, do: Path.join(data_dir(), "tapes")

  @doc "Sandbox overlay directory (`<data_dir>/sandboxes`)."
  @spec sandboxes_dir() :: String.t()
  def sandboxes_dir, do: Path.join(data_dir(), "sandboxes")

  @doc "Per-user root directory (`<data_dir>/users/u<id>` or `_anon`)."
  @spec user_root(user_id()) :: String.t()
  def user_root(user_id), do: Path.join([data_dir(), "users", user_scope(user_id)])

  @doc """
  Per-user, per-session workspace directory.

  Tools (`FsWrite`, `FsEdit`, `Bash`, `Python`) resolve relative paths
  against this. Two users running concurrently must never share one.
  """
  @spec user_workspace(user_id(), String.t()) :: String.t()
  def user_workspace(user_id, session_id) when is_binary(session_id) do
    Path.join([user_root(user_id), "workspaces", session_id])
  end

  @doc "Per-user directory for the user-uploaded avatar."
  @spec user_avatar_dir(user_id()) :: String.t()
  def user_avatar_dir(user_id), do: user_root(user_id)

  @doc "JSONL file storing the (session_id → user_id) ownership map."
  @spec session_owners_path() :: String.t()
  def session_owners_path, do: Path.join(data_dir(), "session_owners.jsonl")

  @typedoc "User identifier — `nil` means anonymous / system context."
  @type user_id :: nil | integer() | String.t()

  defp user_scope(nil), do: "_anon"
  defp user_scope(id) when is_integer(id), do: "u#{id}"
  defp user_scope(id) when is_binary(id) and id != "", do: "u#{id}"
  defp user_scope(_), do: "_anon"
end
