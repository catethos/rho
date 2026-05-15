defmodule Rho.MapAccess do
  @moduledoc """
  Helpers for reading maps that may cross JSON or LiveView boundaries.

  The preferred shape inside the system is still a known key style. Use this at
  boundaries where both atom and string keyed payloads are accepted.
  """

  @doc "Fetch a value by atom or string key, returning `default` when absent."
  @spec get(map() | nil, atom() | String.t(), term()) :: term()
  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> get_string_key(map, Atom.to_string(key), default)
    end
  end

  def get(map, key, default) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> get_atom_key(map, key, default)
    end
  end

  def get(_, _, default), do: default

  defp get_string_key(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp get_atom_key(map, key, default) do
    try do
      case Map.fetch(map, String.to_existing_atom(key)) do
        {:ok, value} -> value
        :error -> default
      end
    rescue
      ArgumentError -> default
    end
  end
end
