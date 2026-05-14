defmodule Rho.Tape.Entry do
  @moduledoc "An immutable fact record in the tape. Monotonic ID, never modified in place."

  @enforce_keys [:kind, :payload, :date]
  defstruct [:id, :kind, :payload, :meta, :date]

  @type kind :: :message | :tool_call | :tool_result | :anchor | :event

  @type t :: %__MODULE__{
          id: integer() | nil,
          kind: kind(),
          payload: map(),
          meta: map(),
          date: String.t()
        }

  @doc "Creates a new entry. `id` is nil until assigned by Store on append."
  def new(kind, payload, meta \\ %{}) do
    %__MODULE__{
      id: nil,
      kind: kind,
      payload: normalize_keys(payload),
      meta: normalize_keys(meta),
      date: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc "Serializes an entry to a JSON-encodable map. Redacts base64 data URIs."
  def to_map(%__MODULE__{} = entry) do
    %{
      "id" => entry.id,
      "kind" => Atom.to_string(entry.kind),
      "payload" => redact_media(entry.payload),
      "meta" => entry.meta,
      "date" => entry.date
    }
  end

  @doc "Encodes an entry to a JSON string."
  def to_json(%__MODULE__{} = entry) do
    entry |> to_map() |> Jason.encode!()
  end

  @doc "Decodes a JSON string into an Entry."
  def from_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, from_map(map)}
      {:error, _} = err -> err
    end
  end

  @doc "Builds an Entry from a decoded JSON map."
  def from_map(%{"kind" => kind, "payload" => payload, "date" => date} = map) do
    %__MODULE__{
      id: map["id"],
      kind: String.to_existing_atom(kind),
      payload: payload,
      meta: map["meta"] || %{},
      date: date
    }
  end

  # -- Key normalization --

  @doc false
  def normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), normalize_keys(v)}
      {k, v} -> {k, normalize_keys(v)}
    end)
  end

  def normalize_keys(map) when is_list(map), do: Enum.map(map, &normalize_keys/1)
  def normalize_keys(map), do: map

  # -- Media redaction --

  defp redact_media(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, redact_media(v)} end)
  end

  defp redact_media(map) when is_list(map), do: Enum.map(map, &redact_media/1)

  defp redact_media(map) when is_binary(map) do
    if String.contains?(map, "data:") and String.contains?(map, ";base64,") do
      Regex.replace(~r/data:[^;]+;base64,[A-Za-z0-9+\/=]+/, map, "[media]")
    else
      map
    end
  end

  defp redact_media(map), do: map
end