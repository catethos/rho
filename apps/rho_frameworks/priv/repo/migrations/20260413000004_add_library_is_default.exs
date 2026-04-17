defmodule RhoFrameworks.Repo.Migrations.AddLibraryIsDefault do
  use Ecto.Migration

  def change do
    alter table(:libraries) do
      add(:is_default, :boolean, default: false, null: false)
    end
  end
end
