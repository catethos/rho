defmodule RhoFrameworks.Frameworks.LensAxisScore do
  use Ecto.Schema
  import Ecto.Changeset

  alias RhoFrameworks.Frameworks.{LensScore, LensAxis, LensVariableScore}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lens_axis_scores" do
    field(:composite, :float)
    field(:band, :integer)

    belongs_to(:lens_score, LensScore)
    belongs_to(:axis, LensAxis)
    has_many(:variable_scores, LensVariableScore, foreign_key: :axis_score_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(axis_score, attrs) do
    axis_score
    |> cast(attrs, [:composite, :band, :lens_score_id, :axis_id])
    |> validate_required([:composite, :band, :lens_score_id, :axis_id])
    |> validate_number(:composite, greater_than_or_equal_to: 0.0)
    |> validate_number(:band, greater_than_or_equal_to: 0)
  end
end
