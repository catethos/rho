defmodule RhoFrameworks.Library.Skeletons do
  @moduledoc """
  Pure transformation for skill skeleton data.

  No IO, no side effects — takes raw data in, returns normalized data out.
  JSON decoding happens at the tool adapter boundary; these functions work
  with already-decoded Elixir terms.
  """

  alias RhoFrameworks.MapAccess

  @required_keys ~w(skill_name category)

  @doc """
  Parse a JSON string into a list of skill maps.

  Returns `{:ok, [map()]}` on success, `{:error, reason}` on failure.
  Validates that the result is a non-empty list where each entry has
  at least `skill_name` and `category`.
  """
  @spec parse_json(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) and list != [] ->
        validate_entries(list)

      {:ok, []} ->
        {:error, :empty_list}

      {:ok, _} ->
        {:error, :not_a_list}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, {:json_decode, Exception.message(err)}}
    end
  end

  @doc """
  Normalize parsed skill maps into DataTable row shape.

  Each row gets: `category`, `cluster`, `skill_name`, `skill_description`,
  `proficiency_levels` (empty list — filled later by proficiency writers).
  """
  @spec to_rows([map()]) :: [map()]
  def to_rows(skills) when is_list(skills) do
    Enum.map(skills, fn s ->
      %{
        category: MapAccess.get(s, :category),
        cluster: MapAccess.get(s, :cluster),
        skill_name: MapAccess.get(s, :skill_name),
        skill_description: MapAccess.get(s, :skill_description),
        proficiency_levels: []
      }
    end)
  end

  defp validate_entries(entries) do
    invalid =
      Enum.filter(entries, fn entry ->
        not Enum.all?(@required_keys, fn key ->
          val = entry[key]
          is_binary(val) and val != ""
        end)
      end)

    case invalid do
      [] -> {:ok, entries}
      _ -> {:error, {:missing_required_keys, @required_keys, length(invalid)}}
    end
  end
end
