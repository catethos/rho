defmodule RhoFrameworks.Frameworks.DuplicateDismissal do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "duplicate_dismissals" do
    belongs_to(:library, RhoFrameworks.Frameworks.Library)
    belongs_to(:skill_a, RhoFrameworks.Frameworks.Skill)
    belongs_to(:skill_b, RhoFrameworks.Frameworks.Skill)

    timestamps(type: :utc_datetime)
  end

  def changeset(dismissal, attrs) do
    dismissal
    |> cast(attrs, [:library_id, :skill_a_id, :skill_b_id])
    |> validate_required([:library_id, :skill_a_id, :skill_b_id])
    |> unique_constraint([:library_id, :skill_a_id, :skill_b_id],
      name: :duplicate_dismissals_library_id_skill_a_id_skill_b_id_index,
      message: "this pair has already been dismissed"
    )
  end
end
