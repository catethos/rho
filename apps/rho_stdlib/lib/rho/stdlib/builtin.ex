defmodule Rho.Stdlib.Builtin do
  @moduledoc """
  Default built-in plugin. Registered first (lowest priority) so that
  user plugins can override any hook.
  """
  @behaviour Rho.Plugin

  @doc "Default session resolver: derives session from tape_name or generates one."
  def resolve_session(%{tape_name: tape_name}) when is_binary(tape_name) do
    {:ok, tape_name}
  end

  def resolve_session(_ctx), do: :skip
end
