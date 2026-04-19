defmodule RhoFrameworks.Flows.Registry do
  @moduledoc """
  Maps string flow IDs to flow modules. No `String.to_atom` — hardcoded map.
  """

  @flows %{
    "create-framework" => RhoFrameworks.Flows.CreateFramework
  }

  @doc "Look up a flow module by string ID. Returns `{:ok, module}` or `:error`."
  @spec get(String.t()) :: {:ok, module()} | :error
  def get(flow_id) when is_binary(flow_id) do
    case Map.fetch(@flows, flow_id) do
      {:ok, _mod} = ok -> ok
      :error -> :error
    end
  end

  @doc "List all registered flow IDs."
  @spec list() :: [String.t()]
  def list, do: Map.keys(@flows)
end
