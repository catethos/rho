defmodule Rho.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :framework_id, references(:frameworks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :category, :string, null: false
      add :cluster, :string, null: false
      add :skill_name, :string, null: false
      add :skill_description, :text
      add :level, :integer, null: false
      add :level_name, :string
      add :level_description, :text
      add :sort_order, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:skills, [:framework_id])
    create index(:skills, [:framework_id, :category, :cluster, :skill_name])
  end
end
