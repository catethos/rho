defmodule Rho.ToolArgs do
  @moduledoc """
  Schema-driven arg casting for tool calls.

  Casts string-keyed args from LLM output to atom keys using the declared
  `parameter_schema` on the tool definition. Only declared keys are cast —
  never calls `String.to_atom/1` on arbitrary input.
  """

  @doc """
  Cast string-keyed args to atom keys using the tool's declared parameter schema.

  Keys not in the schema are left as-is (string-keyed) so tools can still
  access them if needed. Keys already atom-keyed are preserved.

      iex> schema = [name: [type: :string], count: [type: :integer]]
      iex> Rho.ToolArgs.cast(%{"name" => "foo", "count" => 3}, schema)
      %{name: "foo", count: 3}
  """
  @spec cast(map(), keyword()) :: map()
  def cast(args, parameter_schema) when is_list(parameter_schema) do
    declared_keys =
      Enum.reduce(parameter_schema, %{}, fn {atom_key, _opts}, acc ->
        Map.put(acc, Atom.to_string(atom_key), atom_key)
      end)

    result =
      Enum.reduce(args, %{}, fn {key, value}, acc ->
        case {is_atom(key), Map.get(declared_keys, key)} do
          {true, _} ->
            # Already an atom key — keep as-is
            Map.put(acc, key, value)

          {false, nil} ->
            # String key not in schema — keep as string
            Map.put(acc, key, value)

          {false, atom_key} ->
            # String key matches declared schema — cast to atom
            Map.put(acc, atom_key, value)
        end
      end)

    undeclared =
      Enum.filter(args, fn {key, _v} ->
        is_binary(key) and not Map.has_key?(declared_keys, key)
      end)

    if undeclared != [] do
      :telemetry.execute(
        [:rho, :tool, :args_cast],
        %{undeclared_count: length(undeclared)},
        %{undeclared_keys: Enum.map(undeclared, &elem(&1, 0))}
      )
    end

    result
  end

  def cast(args, _non_list_schema), do: args
end
