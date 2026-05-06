defmodule RhoWeb.DataTable.Schema do
  @moduledoc """
  Describes the shape of a DataTable: columns, grouping, and display metadata.

  Used by DataTableProjection, DataTableComponent, and the DataTable plugin
  to drive behaviour from data instead of hardcoded field lists.
  """

  defmodule Column do
    @moduledoc false
    defstruct [:key, :label, type: :text, editable: true, css_class: nil]

    @type t :: %__MODULE__{
            key: atom(),
            label: String.t(),
            type: :text | :number | :textarea | :action,
            editable: boolean(),
            css_class: String.t() | nil
          }
  end

  defstruct title: "Data Table",
            empty_message: "No data yet",
            columns: [],
            child_columns: [],
            children_key: nil,
            child_key_fields: [],
            group_by: [],
            show_id: true,
            children_display: :rows

  @type t :: %__MODULE__{
          title: String.t(),
          empty_message: String.t(),
          columns: [Column.t()],
          child_columns: [Column.t()],
          children_key: atom() | nil,
          child_key_fields: [atom()],
          group_by: [atom()],
          show_id: boolean(),
          children_display: :rows | :panel
        }

  @doc "Returns the list of known field name strings, including `id` and `sort_order`."
  def known_field_names(%__MODULE__{
        columns: cols,
        child_columns: child_cols,
        children_key: children_key
      }) do
    base = ["id", "sort_order"]
    col_names = Enum.map(cols, &Atom.to_string(&1.key))
    child_names = Enum.map(child_cols || [], &Atom.to_string(&1.key))
    children = if children_key, do: [Atom.to_string(children_key)], else: []
    base ++ col_names ++ child_names ++ children
  end

  @doc "Returns a map of default values for all columns (used for row normalization)."
  def column_defaults(%__MODULE__{columns: cols}) do
    Map.new(cols, fn col ->
      default =
        case col.type do
          :number -> 0
          _ -> ""
        end

      {col.key, default}
    end)
  end

  @doc "Normalizes a row map against this schema, filling missing fields with defaults."
  def normalize_row(%__MODULE__{} = schema, row) when is_map(row) do
    defaults = column_defaults(schema)

    Map.new(defaults, fn {key, default} ->
      str_key = Atom.to_string(key)
      value = row[key] || row[str_key] || default
      {key, value}
    end)
  end
end
