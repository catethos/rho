defmodule RhoFrameworks.Frameworks.WorkActivityTag do
  use Ecto.Schema
  import Ecto.Changeset

  alias RhoFrameworks.Frameworks.{Lens, RoleProfile}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "work_activity_tags" do
    field(:tag, :string)
    field(:confidence, :float)
    field(:activity_description, :string)

    belongs_to(:role_profile, RoleProfile)
    belongs_to(:lens, Lens)

    timestamps(type: :utc_datetime)
  end

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:tag, :confidence, :activity_description, :role_profile_id, :lens_id])
    |> validate_required([:tag, :activity_description, :role_profile_id, :lens_id])
    |> validate_inclusion(:tag, [
      "automatable",
      "augmentable",
      "human_essential",
      "data_dependent"
    ])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> unique_constraint([:role_profile_id, :lens_id, :activity_description, :tag],
      name: :work_activity_tags_rp_lens_desc_tag_index,
      message: "this tag already exists for the activity"
    )
  end
end
