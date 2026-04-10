defmodule RhoFrameworks.Frameworks.LensClassification do
  use Ecto.Schema
  import Ecto.Changeset

  alias RhoFrameworks.Frameworks.Lens

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lens_classifications" do
    field(:axis_0_band, :integer)
    field(:axis_1_band, :integer)
    field(:label, :string)
    field(:color, :string)
    field(:description, :string)

    belongs_to(:lens, Lens)

    timestamps(type: :utc_datetime)
  end

  def changeset(classification, attrs) do
    classification
    |> cast(attrs, [:axis_0_band, :axis_1_band, :label, :color, :description, :lens_id])
    |> validate_required([:axis_0_band, :axis_1_band, :label, :lens_id])
    |> validate_number(:axis_0_band, greater_than_or_equal_to: 0)
    |> validate_number(:axis_1_band, greater_than_or_equal_to: 0)
    |> unique_constraint([:lens_id, :axis_0_band, :axis_1_band],
      name: :lens_classifications_lens_id_axis_0_band_axis_1_band_index,
      message: "a classification for this band combination already exists"
    )
  end
end
