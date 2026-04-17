defmodule Rho.Stdlib.DataTable.Schema do
  @moduledoc """
  Declared schema for a data table.

  Two modes:

    * `:dynamic` — accepts arbitrary string-keyed rows with no validation.
      Used for the eagerly-created `"main"` table that LLMs may write into
      with ad-hoc fields.

    * `:strict` — validates each row against declared columns. Unknown fields
      are rejected rather than silently stored. Primitive values are coerced
      (`"1"` → `1`, `"true"` → `true`, etc.). This is the default mode.

  Nested children: if `children_key` is set (e.g. `:proficiency_levels`), each
  row may carry a list of child maps under that key which are validated
  against `child_columns`. This matches the DB `{:array, :map}` embedded shape.
  """

  alias Rho.Stdlib.DataTable.Schema.Column

  defstruct name: nil,
            mode: :strict,
            columns: [],
            key_fields: [],
            children_key: nil,
            child_columns: []

  @type t :: %__MODULE__{
          name: String.t() | nil,
          mode: :strict | :dynamic,
          columns: [Column.t()],
          key_fields: [atom()],
          children_key: atom() | nil,
          child_columns: [Column.t()]
        }

  @doc "Build a dynamic (schemaless) schema. All keys stored as strings; no validation."
  def dynamic(name \\ nil) do
    %__MODULE__{name: name, mode: :dynamic}
  end

  @doc "Declared column name atoms for this schema."
  def column_names(%__MODULE__{columns: cols}), do: Enum.map(cols, & &1.name)

  @doc "Declared child column name atoms for this schema."
  def child_column_names(%__MODULE__{child_columns: cols}), do: Enum.map(cols || [], & &1.name)

  @doc """
  Validate and normalize a row against this schema.

  Returns `{:ok, normalized_row}` or `{:error, reason}`.
  """
  def validate_row(%__MODULE__{mode: :dynamic}, row) when is_map(row) do
    {:ok, Map.new(row, fn {k, v} -> {to_string(k), v} end)}
  end

  def validate_row(%__MODULE__{mode: :strict} = schema, row) when is_map(row) do
    declared = MapSet.new(column_names(schema))
    children_key = schema.children_key

    allowed =
      if children_key,
        do: MapSet.put(declared, children_key),
        else: declared

    with {:ok, atomized} <- atomize_known_keys(row, allowed),
         :ok <- reject_unknown(atomized, allowed),
         {:ok, coerced} <- coerce_columns(atomized, schema.columns),
         {:ok, with_children} <- validate_children(coerced, schema),
         :ok <- check_required(with_children, schema.columns) do
      {:ok, with_children}
    end
  end

  def validate_row(_, _), do: {:error, :invalid_row}

  # --- Helpers ---

  defp atomize_known_keys(row, allowed) do
    result =
      Map.new(row, fn
        {k, v} when is_atom(k) ->
          {k, v}

        {k, v} when is_binary(k) ->
          atom = safe_to_existing_atom(k)

          if atom && MapSet.member?(allowed, atom) do
            {atom, v}
          else
            {k, v}
          end
      end)

    {:ok, result}
  rescue
    _ -> {:error, :invalid_row}
  end

  defp safe_to_existing_atom(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> nil
  end

  defp reject_unknown(row, allowed) do
    unknown =
      row
      |> Map.keys()
      |> Enum.reject(fn
        k when is_atom(k) -> MapSet.member?(allowed, k)
        _ -> false
      end)

    case unknown do
      [] -> :ok
      bad -> {:error, {:unknown_fields, bad}}
    end
  end

  defp coerce_columns(row, columns) do
    Enum.reduce_while(columns, {:ok, row}, fn %Column{name: name, type: type}, {:ok, acc} ->
      case Map.fetch(acc, name) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          coerce_single_column(acc, name, value, type)
      end
    end)
  end

  defp coerce_single_column(acc, name, value, type) do
    case coerce(value, type) do
      {:ok, coerced} -> {:cont, {:ok, Map.put(acc, name, coerced)}}
      {:error, reason} -> {:halt, {:error, {:coerce, name, reason}}}
    end
  end

  defp coerce(v, :any), do: {:ok, v}
  defp coerce(v, :string) when is_binary(v), do: {:ok, v}
  defp coerce(v, :string) when is_integer(v) or is_float(v), do: {:ok, to_string(v)}
  defp coerce(v, :string) when is_boolean(v), do: {:ok, to_string(v)}

  defp coerce(v, :integer) when is_integer(v), do: {:ok, v}

  defp coerce(v, :integer) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_integer}
    end
  end

  defp coerce(v, :float) when is_float(v), do: {:ok, v}
  defp coerce(v, :float) when is_integer(v), do: {:ok, v * 1.0}

  defp coerce(v, :float) when is_binary(v) do
    case Float.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_float}
    end
  end

  defp coerce(v, :boolean) when is_boolean(v), do: {:ok, v}
  defp coerce("true", :boolean), do: {:ok, true}
  defp coerce("false", :boolean), do: {:ok, false}
  defp coerce(_, type), do: {:error, {:bad_type, type}}

  defp validate_children(row, %__MODULE__{children_key: nil}), do: {:ok, row}

  defp validate_children(row, %__MODULE__{children_key: key, child_columns: child_cols}) do
    case Map.get(row, key) do
      nil ->
        {:ok, row}

      children when is_list(children) ->
        validate_child_list(row, key, children, child_cols)

      _other ->
        {:error, {:bad_children, key}}
    end
  end

  defp validate_child_list(row, key, children, child_cols) do
    child_schema = %__MODULE__{mode: :strict, columns: child_cols}

    children
    |> Enum.reduce_while({:ok, []}, fn child, {:ok, acc} ->
      case validate_row(child_schema, child) do
        {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
        {:error, reason} -> {:halt, {:error, {:child, reason}}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Map.put(row, key, Enum.reverse(validated))}
      err -> err
    end
  end

  defp check_required(row, columns) do
    missing =
      columns
      |> Enum.filter(fn col ->
        col.required? and
          case Map.get(row, col.name) do
            nil -> true
            "" -> true
            _ -> false
          end
      end)
      |> Enum.map(& &1.name)

    case missing do
      [] -> :ok
      fields -> {:error, {:missing_required, fields}}
    end
  end
end
