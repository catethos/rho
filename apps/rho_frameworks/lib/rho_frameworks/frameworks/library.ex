defmodule RhoFrameworks.Frameworks.Library do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "libraries" do
    field(:name, :string)
    field(:description, :string)
    field(:type, :string, default: "skill")
    field(:immutable, :boolean, default: false)
    field(:source_key, :string)
    field(:metadata, :map, default: %{})

    # Visibility
    field(:visibility, :string, default: "private")

    # Versioning
    field(:version, :string)
    field(:published_at, :utc_datetime)
    field(:is_default, :boolean, default: false)

    belongs_to(:organization, RhoFrameworks.Accounts.Organization)
    belongs_to(:derived_from, __MODULE__)
    belongs_to(:superseded_by, __MODULE__)
    has_many(:skills, RhoFrameworks.Frameworks.Skill)

    timestamps(type: :utc_datetime)
  end

  def changeset(library, attrs) do
    library
    |> cast(attrs, [
      :name,
      :description,
      :type,
      :immutable,
      :source_key,
      :metadata,
      :visibility,
      :organization_id,
      :derived_from_id,
      :version,
      :published_at,
      :superseded_by_id,
      :is_default
    ])
    |> validate_required([:name, :organization_id])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:type, ["skill", "psychometric", "qualification"])
    |> validate_inclusion(:visibility, ["public", "private"])
    |> validate_version_format()
    |> unique_constraint([:organization_id, :name, :version],
      name: :libraries_org_name_version_index,
      message: "a library with this name and version already exists"
    )
  end

  defp validate_version_format(changeset) do
    case get_change(changeset, :version) do
      nil -> changeset
      _version -> validate_format(changeset, :version, ~r/^\d{4}\.\d+$/)
    end
  end

  def draft?(%__MODULE__{version: nil}), do: true
  def draft?(%__MODULE__{}), do: false

  def published?(%__MODULE__{version: v}) when is_binary(v), do: true
  def published?(%__MODULE__{}), do: false

  def public?(%__MODULE__{visibility: "public"}), do: true
  def public?(%__MODULE__{}), do: false
end
