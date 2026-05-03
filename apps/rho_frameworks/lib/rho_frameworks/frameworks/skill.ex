defmodule RhoFrameworks.Frameworks.Skill do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "skills" do
    field(:slug, :string)
    field(:name, :string)
    field(:description, :string)
    field(:category, :string)
    field(:cluster, :string)
    field(:status, :string, default: "draft")
    field(:sort_order, :integer)
    field(:metadata, :map, default: %{})
    field(:proficiency_levels, {:array, :map}, default: [])
    field(:embedding, Pgvector.Ecto.Vector)
    field(:embedding_text_hash, :binary)
    field(:embedded_at, :utc_datetime_usec)

    belongs_to(:library, RhoFrameworks.Frameworks.Library)
    belongs_to(:source_skill, __MODULE__)
    has_many(:role_skills, RhoFrameworks.Frameworks.RoleSkill)

    timestamps(type: :utc_datetime)
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [
      :name,
      :description,
      :category,
      :cluster,
      :status,
      :sort_order,
      :metadata,
      :proficiency_levels,
      :library_id,
      :source_skill_id,
      :embedding,
      :embedding_text_hash,
      :embedded_at
    ])
    |> validate_required([:name, :category, :library_id])
    |> validate_inclusion(:status, ["draft", "published", "archived"])
    |> generate_slug()
    |> unique_constraint([:library_id, :slug],
      name: :skills_library_id_slug_index,
      message: "a skill with this name already exists in the library"
    )
  end

  def slugify(name) do
    name
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp generate_slug(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :slug, slugify(name))
    end
  end
end
