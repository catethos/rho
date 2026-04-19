defmodule RhoFrameworks.MapAccess do
  @moduledoc """
  Indifferent key access for maps that may have atom or string keys.

  DataTable rows use atom keys, but JSON-decoded LLM output uses string keys.
  This module provides a single access helper so callers don't need inline
  `s["key"] || s[:key]` chains.
  """

  @doc """
  Get a value from a map, checking both atom and string key variants.

  Returns the first truthy value found, or `default` if neither exists.

      iex> RhoFrameworks.MapAccess.get(%{skill_name: "SQL"}, :skill_name)
      "SQL"

      iex> RhoFrameworks.MapAccess.get(%{"skill_name" => "SQL"}, :skill_name)
      "SQL"

      iex> RhoFrameworks.MapAccess.get(%{}, :skill_name)
      ""
  """
  @spec get(map(), atom(), term()) :: term()
  def get(map, key, default \\ "") when is_atom(key) do
    map[key] || map[Atom.to_string(key)] || default
  end
end
