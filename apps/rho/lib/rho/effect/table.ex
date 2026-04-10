defmodule Rho.Effect.Table do
  @moduledoc """
  Effect: populate a data table workspace with columns and rows.

  Dispatched by the turn strategy after a tool returns a
  `%Rho.ToolResponse{}` containing this effect.

  ## Fields

    * `workspace` — target workspace key (default `:data_table`)
    * `columns` — column definitions (optional)
    * `rows` — row data to load
    * `append?` — if true, append rows; if false, replace all (default)
    * `schema_key` — atom key for a predefined schema (e.g. `:skill_library`, `:role_profile`)
    * `mode_label` — display label for the data table mode
  """

  @type t :: %__MODULE__{
          workspace: atom(),
          columns: [map()],
          rows: [map()],
          append?: boolean(),
          schema_key: atom() | nil,
          mode_label: String.t() | nil
        }

  defstruct workspace: :data_table,
            columns: [],
            rows: [],
            append?: false,
            schema_key: nil,
            mode_label: nil
end
