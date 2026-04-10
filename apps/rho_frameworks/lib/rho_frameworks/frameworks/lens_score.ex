defmodule RhoFrameworks.Frameworks.LensScore do
  use Ecto.Schema
  import Ecto.Changeset

  alias RhoFrameworks.Frameworks.{Lens, LensAxisScore}
  alias RhoFrameworks.Frameworks.Skill
  alias RhoFrameworks.Frameworks.RoleProfile

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lens_scores" do
    field(:scored_at, :utc_datetime)
    field(:scoring_method, :string)
    field(:classification, :string)
    field(:version, :integer, default: 1)

    belongs_to(:lens, Lens)
    belongs_to(:skill, Skill)
    belongs_to(:role_profile, RoleProfile)

    has_many(:axis_scores, LensAxisScore)

    timestamps(type: :utc_datetime)
  end

  def changeset(score, attrs) do
    score
    |> cast(attrs, [
      :scored_at,
      :scoring_method,
      :classification,
      :version,
      :lens_id,
      :skill_id,
      :role_profile_id
    ])
    |> validate_required([:scored_at, :scoring_method, :lens_id])
    |> validate_inclusion(:scoring_method, ["manual", "llm", "hybrid"])
    |> validate_exactly_one_target()
  end

  defp validate_exactly_one_target(changeset) do
    skill_id = get_field(changeset, :skill_id)
    role_profile_id = get_field(changeset, :role_profile_id)

    targets_set =
      [skill_id, role_profile_id]
      |> Enum.count(&(not is_nil(&1)))

    case targets_set do
      1 ->
        changeset

      0 ->
        add_error(changeset, :skill_id, "exactly one target (skill or role_profile) must be set")

      _ ->
        add_error(changeset, :skill_id, "only one target (skill or role_profile) may be set")
    end
  end
end
