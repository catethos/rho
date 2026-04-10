defmodule RhoFrameworks.Frameworks.LensVariableScore do
  use Ecto.Schema
  import Ecto.Changeset

  alias RhoFrameworks.Frameworks.{LensAxisScore, LensVariable}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lens_variable_scores" do
    field(:raw_score, :float)
    field(:adjusted_score, :float)
    field(:weighted_score, :float)
    field(:rationale, :string)

    belongs_to(:axis_score, LensAxisScore)
    belongs_to(:variable, LensVariable)

    timestamps(type: :utc_datetime)
  end

  def changeset(variable_score, attrs) do
    variable_score
    |> cast(attrs, [
      :raw_score,
      :adjusted_score,
      :weighted_score,
      :rationale,
      :axis_score_id,
      :variable_id
    ])
    |> validate_required([
      :raw_score,
      :adjusted_score,
      :weighted_score,
      :axis_score_id,
      :variable_id
    ])
  end
end
