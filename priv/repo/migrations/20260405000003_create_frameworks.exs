defmodule Rho.Repo.Migrations.CreateFrameworks do
  use Ecto.Migration

  def change do
    create table(:frameworks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:frameworks, [:user_id])
    create unique_index(:frameworks, [:user_id, :name])
  end
end
