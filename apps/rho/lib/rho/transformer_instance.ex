defmodule Rho.TransformerInstance do
  @moduledoc """
  A registered transformer instance with its config and scope.

  Same shape as `Rho.PluginInstance` — a module may implement both
  `Rho.Plugin` and `Rho.Transformer`, but registers separately for
  each role.
  """

  @enforce_keys [:module]
  defstruct module: nil, opts: [], scope: :global, priority: 0

  @type t :: %__MODULE__{
          module: module(),
          opts: keyword(),
          scope: :global | {:agent, atom()},
          priority: non_neg_integer()
        }
end
