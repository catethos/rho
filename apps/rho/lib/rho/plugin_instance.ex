defmodule Rho.PluginInstance do
  @moduledoc "A configured plugin: module + instance opts + scope/priority."

  defstruct module: nil,
            opts: [],
            scope: :global,
            priority: 0

  @type t :: %__MODULE__{
          module: module(),
          opts: keyword(),
          scope: :global | {:agent, atom()},
          priority: non_neg_integer()
        }
end
