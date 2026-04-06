defmodule Rho.SkillStore.Repo.Migrations.CreateTables do
  use Ecto.Migration

  def change do
    create table(:companies, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:name, :string, null: false)
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create table(:frameworks) do
      add(:company_id, references(:companies, type: :string, on_delete: :delete_all))
      add(:name, :string, null: false)
      add(:type, :string, null: false, default: "company")
      add(:source, :string)
      add(:row_count, :integer, default: 0)
      add(:skill_count, :integer, default: 0)
      timestamps(type: :utc_datetime)
    end

    create(index(:frameworks, [:company_id]))
    create(index(:frameworks, [:type]))

    create table(:framework_rows) do
      add(:framework_id, references(:frameworks, on_delete: :delete_all), null: false)
      add(:role, :string, default: "")
      add(:category, :string, default: "")
      add(:cluster, :string, default: "")
      add(:skill_name, :string, null: false)
      add(:skill_description, :string, default: "")
      add(:level, :integer, default: 0)
      add(:level_name, :string, default: "")
      add(:level_description, :string, default: "")
      add(:skill_code, :string, default: "")
      timestamps(type: :utc_datetime)
    end

    create(index(:framework_rows, [:framework_id]))
    create(index(:framework_rows, [:framework_id, :role]))
    create(index(:framework_rows, [:framework_id, :skill_name]))
  end
end
