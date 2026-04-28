defmodule Rho.Effect.Table do
  @moduledoc """
  Effect: populate a data table workspace with columns and rows.

  Dispatched by the turn strategy after a tool returns a
  `%Rho.ToolResponse{}` containing this effect.

  ## Fields

    * `workspace` — target workspace key (default `:data_table`)
    * `table_name` — named table on the per-session DataTable server
      (default `"main"`). When set to something other than `"main"`,
      callers should first `ensure_table/4` the table with a declared
      `Rho.Stdlib.DataTable.Schema`.
    * `columns` — column definitions (optional)
    * `rows` — row data to load
    * `append?` — if true, append rows; if false, replace all (default)
    * `schema_key` — atom key identifying a predefined web schema
      (e.g. `:skill_library`, `:role_profile`). Used by the LiveView to
      pick the right renderer/column set. Independent of `table_name`:
      two effects targeting the `"main"` table may render with
      different web schemas.
    * `mode_label` — display label for the data table mode
    * `metadata` — arbitrary map passed through to the web component
      (e.g. `%{library_id: "..."}` for navigation links)
    * `skip_write?` — when true the dispatcher emits only the UI
      `:view_change` signal and skips writing rows. Used by tools that
      have already written via `RhoFrameworks.Workbench` and only need
      the workspace tab switch.
  """

  @type t :: %__MODULE__{
          workspace: atom(),
          table_name: String.t(),
          columns: [map()],
          rows: [map()],
          append?: boolean(),
          schema_key: atom() | nil,
          mode_label: String.t() | nil,
          metadata: map(),
          skip_write?: boolean()
        }

  defstruct workspace: :data_table,
            table_name: "main",
            columns: [],
            rows: [],
            append?: false,
            schema_key: nil,
            mode_label: nil,
            metadata: %{},
            skip_write?: false
end
