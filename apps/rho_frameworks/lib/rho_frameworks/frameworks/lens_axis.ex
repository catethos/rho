defmodule RhoFrameworks.Frameworks.LensAxis do
  use Ecto.Schema
  import Ecto.Changeset

  alias RhoFrameworks.Frameworks.{Lens, LensVariable, LensAxisScore}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lens_axes" do
    field(:sort_order, :integer)
    field(:name, :string)
    field(:short_name, :string)
    field(:band_thresholds, {:array, :float})
    field(:band_labels, {:array, :string})

    belongs_to(:lens, Lens)
    has_many(:variables, LensVariable, foreign_key: :axis_id)
    has_many(:axis_scores, LensAxisScore, foreign_key: :axis_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(axis, attrs) do
    axis
    |> cast(attrs, [:sort_order, :name, :short_name, :band_thresholds, :band_labels, :lens_id])
    |> validate_required([:sort_order, :name, :band_thresholds, :band_labels, :lens_id])
    |> validate_band_labels_count()
    |> unique_constraint([:lens_id, :sort_order],
      name: :lens_axes_lens_id_sort_order_index,
      message: "an axis with this sort order already exists for the lens"
    )
  end

  defp validate_band_labels_count(changeset) do
    thresholds = get_field(changeset, :band_thresholds) || []
    labels = get_field(changeset, :band_labels) || []

    if length(labels) == length(thresholds) + 1 do
      changeset
    else
      add_error(changeset, :band_labels, "count must equal band_thresholds count + 1")
    end
  end
end
