defmodule RhoFrameworks.Repo.Migrations.InitialSchema do
  use Ecto.Migration

  def change do
    # Users
    create table(:users, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:email, :string, null: false)
      add(:hashed_password, :string, null: false)
      add(:display_name, :string)
      add(:context, :text)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:users, [:email]))

    # User tokens
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

    # Organizations
    create table(:organizations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:personal, :boolean, default: false, null: false)
      add(:context, :text)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:organizations, [:slug]))

    # Memberships
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

    # Libraries
    create table(:libraries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:type, :string, null: false, default: "skill")
      add(:immutable, :boolean, null: false, default: false)
      add(:source_key, :string)
      add(:metadata, :map, default: %{})

      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:derived_from_id, references(:libraries, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:libraries, [:organization_id, :name]))
    create(index(:libraries, [:organization_id, :type]))
    create(index(:libraries, [:derived_from_id]))

    # Skills
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
      add(:proficiency_levels, :map, default: [])

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

    # Role Profiles
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
      add(:work_activities, :map, default: [])
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

    # Role Skills (join)
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

    # Duplicate Dismissals
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
  end
end
