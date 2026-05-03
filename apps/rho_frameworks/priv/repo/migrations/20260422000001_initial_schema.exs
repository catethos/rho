defmodule RhoFrameworks.Repo.Migrations.InitialSchema do
  use Ecto.Migration

  def change do
    # ── Users ──────────────────────────────────────────────────────────

    create table(:users, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:email, :string, null: false)
      add(:hashed_password, :string, null: false)
      add(:display_name, :string)
      add(:context, :text)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:users, [:email]))

    # ── User Tokens ────────────────────────────────────────────────────

    create table(:users_tokens, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:token, :binary, null: false)
      add(:context, :string, null: false)
      add(:sent_to, :string)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(index(:users_tokens, [:user_id]))
    create(unique_index(:users_tokens, [:token, :context]))

    # ── Organizations ──────────────────────────────────────────────────

    create table(:organizations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:personal, :boolean, default: false, null: false)
      add(:context, :text)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:organizations, [:slug]))

    # ── Memberships ────────────────────────────────────────────────────

    create table(:memberships, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:role, :string, null: false, default: "member")
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:memberships, [:user_id, :organization_id]))
    create(index(:memberships, [:organization_id]))

    # ── Libraries ──────────────────────────────────────────────────────

    create table(:libraries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:type, :string, null: false, default: "skill")
      add(:immutable, :boolean, null: false, default: false)
      add(:source_key, :string)
      add(:metadata, :map, default: %{})
      add(:visibility, :string, null: false, default: "private")
      add(:version, :string)
      add(:published_at, :utc_datetime)
      add(:is_default, :boolean, null: false, default: false)

      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:derived_from_id, references(:libraries, type: :binary_id, on_delete: :nilify_all))
      add(:superseded_by_id, references(:libraries, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:libraries, [:organization_id, :name, :version],
        name: :libraries_org_name_version_index
      )
    )

    create(index(:libraries, [:organization_id, :type]))
    create(index(:libraries, [:derived_from_id]))
    create(index(:libraries, [:visibility]))
    create(index(:libraries, [:organization_id, :name, :published_at]))

    # ── Skills ─────────────────────────────────────────────────────────

    create table(:skills, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:slug, :string, null: false)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:category, :string, null: false)
      add(:cluster, :string)
      add(:status, :string, null: false, default: "draft")
      add(:sort_order, :integer)
      add(:metadata, :map, default: %{})
      add(:proficiency_levels, {:array, :map}, default: [])

      add(:library_id, references(:libraries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:source_skill_id, references(:skills, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:skills, [:library_id, :slug]))
    create(index(:skills, [:library_id, :category]))
    create(index(:skills, [:library_id, :status]))
    create(index(:skills, [:source_skill_id]))

    # ── Role Profiles ──────────────────────────────────────────────────

    create table(:role_profiles, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:role_family, :string)
      add(:seniority_level, :integer)
      add(:seniority_label, :string)
      add(:description, :text)
      add(:purpose, :text)
      add(:accountabilities, :text)
      add(:success_metrics, :text)
      add(:qualifications, :text)
      add(:reporting_context, :text)
      add(:headcount, :integer, default: 1)
      add(:metadata, :map, default: %{})
      add(:work_activities, {:array, :map}, default: [])
      add(:visibility, :string, null: false, default: "private")
      add(:immutable, :boolean, null: false, default: false)

      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      add(
        :source_role_profile_id,
        references(:role_profiles, type: :binary_id, on_delete: :nilify_all)
      )

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:role_profiles, [:organization_id, :name]))
    create(index(:role_profiles, [:source_role_profile_id]))
    create(index(:role_profiles, [:organization_id, :role_family]))
    create(index(:role_profiles, [:organization_id, :visibility]))

    # ── Role Skills (join) ─────────────────────────────────────────────

    create table(:role_skills, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:min_expected_level, :integer, null: false)
      add(:weight, :float, default: 1.0)
      add(:required, :boolean, default: true)

      add(
        :role_profile_id,
        references(:role_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:skill_id, references(:skills, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:role_skills, [:role_profile_id, :skill_id]))
    create(index(:role_skills, [:skill_id]))

    # ── Duplicate Dismissals ───────────────────────────────────────────

    create table(:duplicate_dismissals, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:library_id, references(:libraries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:skill_a_id, references(:skills, type: :binary_id, on_delete: :delete_all), null: false)
      add(:skill_b_id, references(:skills, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:duplicate_dismissals, [:library_id, :skill_a_id, :skill_b_id]))
    create(index(:duplicate_dismissals, [:library_id]))

    # ── Lenses ─────────────────────────────────────────────────────────

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

    # ── Lens Axes ──────────────────────────────────────────────────────

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

    # ── Lens Variables ─────────────────────────────────────────────────

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

    # ── Lens Classifications ───────────────────────────────────────────

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

    # ── Lens Scores ────────────────────────────────────────────────────

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
    create(index(:lens_scores, [:lens_id, :role_profile_id, :skill_id]))

    # ── Lens Axis Scores ───────────────────────────────────────────────

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

    create(index(:lens_axis_scores, [:lens_score_id]))

    # ── Lens Variable Scores ───────────────────────────────────────────

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

    # ── Work Activity Tags ─────────────────────────────────────────────

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
