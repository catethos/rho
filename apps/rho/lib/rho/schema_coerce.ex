defmodule Rho.SchemaCoerce do
  @moduledoc """
  Schema-guided type coercion for LLM output.

  Recursively walks a value and coerces it to match the expected type from a
  NimbleOptions parameter schema. Produces a repair log recording every
  coercion performed.

  Ported from `simplify_baml/src/parser.rs` lines 227-561 with safety
  adaptations for tool invocation (no nil→"", no arbitrary atom creation,
  strict object unwrapping).
  """

  @type repair :: %{
          field: atom() | nil,
          from: String.t(),
          to: String.t(),
          original: term()
        }

  @type result :: {:ok, term(), [repair()]} | {:error, term()}

  # Known wrapper keys for object unwrapping in :tool_call mode
  @wrapper_keys ~w(value Value text Text result Result)

  # Extended wrapper keys for :extraction mode
  @extraction_wrapper_keys @wrapper_keys ++ ~w(string String)

  @doc """
  Coerce all fields in a map against a parameter_schema keyword list.

  Options:
    - `mode`: `:tool_call` (default) or `:extraction`

  Returns `{:ok, coerced_map, repairs}` or `{:error, reason}`.
  """
  @spec coerce_fields(map(), keyword(), keyword()) :: {:ok, map(), [repair()]} | {:error, term()}
  def coerce_fields(args, parameter_schema, opts \\ [])
      when is_map(args) and is_list(parameter_schema) do
    mode = Keyword.get(opts, :mode, :tool_call)

    Enum.reduce_while(parameter_schema, {:ok, args, []}, fn {field, field_opts},
                                                            {:ok, acc, repairs} ->
      type = Keyword.get(field_opts, :type, :string)
      required = Keyword.get(field_opts, :required, false)
      coerce_field(acc, field, type, required, mode, repairs)
    end)
  end

  defp coerce_field(acc, field, type, required, mode, repairs) do
    case Map.fetch(acc, field) do
      {:ok, value} ->
        case coerce(value, type, mode: mode) do
          {:ok, coerced, field_repairs} ->
            tagged = Enum.map(field_repairs, &Map.put(&1, :field, field))
            {:cont, {:ok, Map.put(acc, field, coerced), repairs ++ tagged}}

          {:error, reason} ->
            {:halt, {:error, {:coerce_failed, field, reason}}}
        end

      :error when required ->
        {:halt, {:error, {:missing_required, field}}}

      :error ->
        {:cont, {:ok, acc, repairs}}
    end
  end

  @doc """
  Coerce a single value to match the expected type.

  Options:
    - `mode`: `:tool_call` (default) or `:extraction`
  """
  @spec coerce(term(), term(), keyword()) :: result()
  def coerce(value, type, opts \\ [])

  def coerce(value, :string, opts), do: coerce_string(value, opts)
  def coerce(value, :integer, opts), do: coerce_integer(value, opts)
  def coerce(value, :pos_integer, opts), do: coerce_pos_integer(value, opts)
  def coerce(value, :float, opts), do: coerce_float(value, opts)
  def coerce(value, :number, opts), do: coerce_number(value, opts)
  def coerce(value, :boolean, opts), do: coerce_boolean(value, opts)
  def coerce(value, :map, _opts), do: coerce_map(value)
  def coerce(value, {:in, variants}, opts), do: coerce_in(value, variants, opts)
  def coerce(value, {:list, inner}, opts), do: coerce_list(value, inner, opts)

  def coerce(value, {:map, key_type, value_type}, opts),
    do: coerce_typed_map(value, key_type, value_type, opts)

  # Pass through unknown types unchanged
  def coerce(value, _type, _opts), do: {:ok, value, []}

  # --- String coercion ---

  defp coerce_string(value, _opts) when is_binary(value), do: {:ok, value, []}

  defp coerce_string(value, _opts) when is_number(value) do
    {:ok, to_string(value), [repair(:number, :string, value)]}
  end

  defp coerce_string(value, _opts) when is_boolean(value) do
    {:ok, to_string(value), [repair(:boolean, :string, value)]}
  end

  defp coerce_string(nil, opts) do
    if Keyword.get(opts, :mode, :tool_call) == :extraction do
      {:ok, "", [repair(nil, :string, nil)]}
    else
      {:error, :nil_for_string}
    end
  end

  defp coerce_string(value, opts) when is_map(value) do
    case unwrap_object(value, opts) do
      {:ok, inner} -> coerce_string(inner, opts)
      :error -> {:error, {:cannot_coerce, :map, :string}}
    end
  end

  defp coerce_string(_value, _opts), do: {:error, {:cannot_coerce, :unknown, :string}}

  # --- Integer coercion ---

  defp coerce_integer(value, _opts) when is_integer(value), do: {:ok, value, []}

  defp coerce_integer(value, _opts) when is_float(value) do
    if Float.round(value) == value do
      {:ok, trunc(value), [repair(:float, :integer, value)]}
    else
      {:error, {:non_integral_float, value}}
    end
  end

  defp coerce_integer(value, opts) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} ->
        {:ok, int, [repair(:string, :integer, value)]}

      _ ->
        # Try parsing as float first (e.g. "3.0")
        case Float.parse(value) do
          {f, ""} -> coerce_integer(f, opts)
          _ -> {:error, {:cannot_parse_integer, value}}
        end
    end
  end

  defp coerce_integer(value, opts) when is_map(value) do
    case unwrap_object(value, opts) do
      {:ok, inner} -> coerce_integer(inner, opts)
      :error -> {:error, {:cannot_coerce, :map, :integer}}
    end
  end

  defp coerce_integer(_value, _opts), do: {:error, {:cannot_coerce, :unknown, :integer}}

  # --- Pos integer coercion ---

  defp coerce_pos_integer(value, opts) do
    case coerce_integer(value, opts) do
      {:ok, int, repairs} when int > 0 -> {:ok, int, repairs}
      {:ok, int, _repairs} -> {:error, {:not_positive, int}}
      error -> error
    end
  end

  # --- Float coercion ---

  defp coerce_float(value, _opts) when is_float(value), do: {:ok, value, []}

  defp coerce_float(value, _opts) when is_integer(value) do
    {:ok, value * 1.0, [repair(:integer, :float, value)]}
  end

  defp coerce_float(value, _opts) when is_binary(value) do
    case Float.parse(value) do
      {f, ""} ->
        {:ok, f, [repair(:string, :float, value)]}

      _ ->
        case Integer.parse(value) do
          {i, ""} -> {:ok, i * 1.0, [repair(:string, :float, value)]}
          _ -> {:error, {:cannot_parse_float, value}}
        end
    end
  end

  defp coerce_float(value, opts) when is_map(value) do
    case unwrap_object(value, opts) do
      {:ok, inner} -> coerce_float(inner, opts)
      :error -> {:error, {:cannot_coerce, :map, :float}}
    end
  end

  defp coerce_float(_value, _opts), do: {:error, {:cannot_coerce, :unknown, :float}}

  # --- Number coercion (int or float) ---

  defp coerce_number(value, _opts) when is_number(value), do: {:ok, value, []}

  defp coerce_number(value, _opts) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} ->
        {:ok, int, [repair(:string, :number, value)]}

      _ ->
        case Float.parse(value) do
          {f, ""} -> {:ok, f, [repair(:string, :number, value)]}
          _ -> {:error, {:cannot_parse_number, value}}
        end
    end
  end

  defp coerce_number(value, opts) when is_map(value) do
    case unwrap_object(value, opts) do
      {:ok, inner} -> coerce_number(inner, opts)
      :error -> {:error, {:cannot_coerce, :map, :number}}
    end
  end

  defp coerce_number(_value, _opts), do: {:error, {:cannot_coerce, :unknown, :number}}

  # --- Boolean coercion ---

  defp coerce_boolean(value, _opts) when is_boolean(value), do: {:ok, value, []}

  defp coerce_boolean(value, _opts) when is_binary(value) do
    case String.downcase(value) do
      v when v in ~w(true yes 1) -> {:ok, true, [repair(:string, :boolean, value)]}
      v when v in ~w(false no 0) -> {:ok, false, [repair(:string, :boolean, value)]}
      _ -> {:error, {:cannot_parse_boolean, value}}
    end
  end

  defp coerce_boolean(value, _opts) when is_integer(value) do
    {:ok, value != 0, [repair(:integer, :boolean, value)]}
  end

  defp coerce_boolean(value, opts) when is_map(value) do
    case unwrap_object(value, opts) do
      {:ok, inner} -> coerce_boolean(inner, opts)
      :error -> {:error, {:cannot_coerce, :map, :boolean}}
    end
  end

  defp coerce_boolean(_value, _opts), do: {:error, {:cannot_coerce, :unknown, :boolean}}

  # --- Map coercion (untyped :map) ---

  defp coerce_map(value) when is_map(value), do: {:ok, value, []}

  defp coerce_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> {:ok, map, [repair(:string, :map, "(json)")]}
      _ -> {:error, {:cannot_coerce, :string, :map}}
    end
  end

  defp coerce_map(_value), do: {:error, {:cannot_coerce, :unknown, :map}}

  # --- {:in, variants} coercion (enum-like) ---

  defp coerce_in(value, variants, _opts) do
    case to_comparable_string(value) do
      nil -> {:error, {:cannot_coerce_to_variant, value}}
      str -> find_variant(str, value, variants)
    end
  end

  defp find_variant(str, value, variants) do
    case Enum.find(variants, fn v -> to_string(v) == str end) do
      nil -> find_variant_case_insensitive(str, value, variants)
      exact -> {:ok, exact, []}
    end
  end

  defp find_variant_case_insensitive(str, value, variants) do
    lower = String.downcase(str)

    case Enum.find(variants, fn v -> String.downcase(to_string(v)) == lower end) do
      nil -> {:error, {:not_a_variant, str, variants}}
      match -> {:ok, match, [repair(:case_mismatch, :in, value)]}
    end
  end

  defp to_comparable_string(v) when is_binary(v), do: v
  defp to_comparable_string(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp to_comparable_string(v) when is_number(v), do: to_string(v)
  defp to_comparable_string(v) when is_boolean(v), do: to_string(v)
  defp to_comparable_string(_), do: nil

  # --- {:list, inner} coercion ---

  defp coerce_list(value, inner_type, opts) when is_list(value) do
    result =
      Enum.reduce_while(value, {:ok, [], []}, fn item, {:ok, acc, repairs} ->
        case coerce(item, inner_type, opts) do
          {:ok, coerced, item_repairs} ->
            {:cont, {:ok, acc ++ [coerced], repairs ++ item_repairs}}

          {:error, reason} ->
            {:halt, {:error, {:list_item_coerce_failed, reason}}}
        end
      end)

    result
  end

  # Scalar-to-list wrap
  defp coerce_list(value, inner_type, opts) do
    case coerce(value, inner_type, opts) do
      {:ok, coerced, inner_repairs} ->
        {:ok, [coerced], [repair(:scalar, :list, value) | inner_repairs]}

      {:error, reason} ->
        {:error, {:scalar_to_list_failed, reason}}
    end
  end

  # --- {:map, key_type, value_type} coercion ---

  defp coerce_typed_map(value, _key_type, value_type, opts) when is_map(value) do
    result =
      Enum.reduce_while(value, {:ok, %{}, []}, fn {k, v}, {:ok, acc, repairs} ->
        case coerce(v, value_type, opts) do
          {:ok, coerced_v, v_repairs} ->
            {:cont, {:ok, Map.put(acc, k, coerced_v), repairs ++ v_repairs}}

          {:error, reason} ->
            {:halt, {:error, {:map_value_coerce_failed, k, reason}}}
        end
      end)

    result
  end

  defp coerce_typed_map(_value, _key_type, _value_type, _opts) do
    {:error, {:cannot_coerce, :unknown, :map}}
  end

  # --- Object unwrapping ---

  defp unwrap_object(map, opts) when is_map(map) do
    mode = Keyword.get(opts, :mode, :tool_call)

    keys =
      if mode == :extraction do
        @extraction_wrapper_keys
      else
        @wrapper_keys
      end

    case find_wrapper_value(map, keys) do
      {:found, inner} -> {:ok, inner}
      nil -> unwrap_singleton(map, mode)
    end
  end

  defp find_wrapper_value(map, keys) do
    Enum.find_value(keys, fn k ->
      case Map.fetch(map, k) do
        {:ok, v} -> {:found, v}
        :error -> nil
      end
    end)
  end

  defp unwrap_singleton(map, :extraction) when map_size(map) == 1 do
    [{_k, v}] = Map.to_list(map)
    {:ok, v}
  end

  defp unwrap_singleton(_map, _mode), do: :error

  # --- Helpers ---

  defp repair(from, to, original) do
    %{field: nil, from: from, to: to, original: original}
  end
end
