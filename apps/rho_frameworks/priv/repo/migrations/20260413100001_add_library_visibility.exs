defmodule RhoFrameworks.Repo.Migrations.AddLibraryVisibility do
  use Ecto.Migration

  def change do
    alter table(:libraries) do
      add(:visibility, :string, default: "private", null: false)
    end

    create(index(:libraries, [:visibility]))
  end
end
