defmodule RhoFrameworks.Frameworks.Lens do
  use Ecto.Schema
  import Ecto.Changeset

  alias RhoFrameworks.Accounts.Organization
  alias RhoFrameworks.Frameworks.{LensAxis, LensClassification, LensScore}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lenses" do
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:status, :string, default: "draft")
    field(:score_target, :string)
    field(:scoring_method, :string)

    belongs_to(:organization, Organization)
    has_many(:axes, LensAxis)
    has_many(:classifications, LensClassification)
    has_many(:scores, LensScore)

    timestamps(type: :utc_datetime)
  end

  def changeset(lens, attrs) do
    lens
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :status,
      :score_target,
      :scoring_method,
      :organization_id
    ])
    |> validate_required([:name, :slug, :organization_id])
    |> validate_inclusion(:status, ["draft", "active", "archived"])
    |> validate_inclusion(:score_target, ["skill", "role_profile", "individual_profile"])
    |> validate_inclusion(:scoring_method, ["manual", "llm", "hybrid", "derived"])
    |> unique_constraint([:organization_id, :slug],
      name: :lenses_organization_id_slug_index,
      message: "a lens with this slug already exists in the organization"
    )
  end
end
