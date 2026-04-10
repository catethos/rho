defmodule RhoFrameworks.Frameworks.LensVariable do
  use Ecto.Schema
  import Ecto.Changeset

  alias RhoFrameworks.Frameworks.LensAxis

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lens_variables" do
    field(:key, :string)
    field(:name, :string)
    field(:weight, :float)
    field(:description, :string)
    field(:inverse, :boolean, default: false)

    belongs_to(:axis, LensAxis)

    timestamps(type: :utc_datetime)
  end

  def changeset(variable, attrs) do
    variable
    |> cast(attrs, [:key, :name, :weight, :description, :inverse, :axis_id])
    |> validate_required([:key, :name, :weight, :axis_id])
    |> validate_number(:weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> unique_constraint([:axis_id, :key],
      name: :lens_variables_axis_id_key_index,
      message: "a variable with this key already exists for the axis"
    )
  end
end
