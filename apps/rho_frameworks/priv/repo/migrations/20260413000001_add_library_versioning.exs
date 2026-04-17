defmodule RhoFrameworks.Repo.Migrations.AddLibraryVersioning do
  use Ecto.Migration

  def change do
    alter table(:libraries) do
      add(:version, :string)
      add(:published_at, :utc_datetime)
      add(:superseded_by_id, references(:libraries, type: :binary_id, on_delete: :nilify_all))
    end

    # Drop old unique index, create new one that includes version
    drop(unique_index(:libraries, [:organization_id, :name]))

    create(
      unique_index(:libraries, [:organization_id, :name, :version],
        name: :libraries_org_name_version_index
      )
    )

    create(index(:libraries, [:organization_id, :name, :published_at]))

    # Role profiles: track which library version they were built against
    alter table(:role_profiles) do
      add(:library_id, references(:libraries, type: :binary_id, on_delete: :nilify_all))
      add(:library_version, :string)
    end
  end
end
