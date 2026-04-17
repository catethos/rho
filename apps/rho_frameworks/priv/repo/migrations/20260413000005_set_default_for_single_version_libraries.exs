defmodule RhoFrameworks.Repo.Migrations.SetDefaultForSingleVersionLibraries do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE libraries
    SET is_default = true
    WHERE version IS NOT NULL
      AND id IN (
        SELECT l.id
        FROM libraries l
        WHERE l.version IS NOT NULL
        GROUP BY l.organization_id, l.name
        HAVING COUNT(*) = 1
      )
    """)
  end

  def down do
    execute("UPDATE libraries SET is_default = false")
  end
end
