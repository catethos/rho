defmodule RhoFrameworks.Repo.Migrations.CreateLensTables do
  use Ecto.Migration

  def change do
    # Lenses
    create table(:lenses, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:description, :text)
      add(:status, :string, null: false, default: "draft")
      add(:score_target, :string)
      add(:scoring_method, :string)

      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:lenses, [:organization_id, :slug]))

    # Lens Axes
    create table(:lens_axes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:sort_order, :integer, null: false)
      add(:name, :string, null: false)
      add(:short_name, :string)
      add(:band_thresholds, {:array, :float}, null: false)
      add(:band_labels, {:array, :string}, null: false)

      add(:lens_id, references(:lenses, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:lens_axes, [:lens_id, :sort_order]))

    # Lens Variables
    create table(:lens_variables, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:key, :string, null: false)
      add(:name, :string, null: false)
      add(:weight, :float, null: false)
      add(:description, :text)
      add(:inverse, :boolean, null: false, default: false)

      add(:axis_id, references(:lens_axes, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:lens_variables, [:axis_id, :key]))

    # Lens Classifications (2-axis matrix)
    create table(:lens_classifications, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:axis_0_band, :integer, null: false)
      add(:axis_1_band, :integer, null: false)
      add(:label, :string, null: false)
      add(:color, :string)
      add(:description, :text)

      add(:lens_id, references(:lenses, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:lens_classifications, [:lens_id, :axis_0_band, :axis_1_band]))

    # Lens Scores
    create table(:lens_scores, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:scored_at, :utc_datetime, null: false)
      add(:scoring_method, :string, null: false)
      add(:classification, :string)
      add(:version, :integer, null: false, default: 1)

      add(:lens_id, references(:lenses, type: :binary_id, on_delete: :delete_all), null: false)
      add(:skill_id, references(:skills, type: :binary_id, on_delete: :delete_all))
      add(:role_profile_id, references(:role_profiles, type: :binary_id, on_delete: :delete_all))

      timestamps(type: :utc_datetime)
    end

    create(index(:lens_scores, [:lens_id, :classification]))

    # Lens Axis Scores
    create table(:lens_axis_scores, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:composite, :float, null: false)
      add(:band, :integer, null: false)

      add(
        :lens_score_id,
        references(:lens_scores, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:axis_id, references(:lens_axes, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime)
    end

    # Lens Variable Scores
    create table(:lens_variable_scores, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:raw_score, :float, null: false)
      add(:adjusted_score, :float, null: false)
      add(:weighted_score, :float, null: false)
      add(:rationale, :text)

      add(
        :axis_score_id,
        references(:lens_axis_scores, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :variable_id,
        references(:lens_variables, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime)
    end

    # Work Activity Tags
    create table(:work_activity_tags, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tag, :string, null: false)
      add(:confidence, :float)
      add(:activity_description, :text, null: false)

      add(
        :role_profile_id,
        references(:role_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:lens_id, references(:lenses, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:work_activity_tags, [:role_profile_id, :lens_id, :activity_description, :tag],
        name: :work_activity_tags_rp_lens_desc_tag_index
      )
    )

    create(index(:work_activity_tags, [:role_profile_id]))
  end
end
