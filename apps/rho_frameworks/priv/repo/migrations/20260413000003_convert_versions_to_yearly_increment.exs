defmodule RhoFrameworks.Repo.Migrations.ConvertVersionsToYearlyIncrement do
  use Ecto.Migration

  def up do
    # Convert existing YYYY.MM (and YYYY.MM.N) versions to YYYY.N format.
    # Groups by (organization_id, name, year) and assigns sequential numbers
    # ordered by the original version.
    execute("""
    UPDATE libraries
    SET version = (
      SELECT substr(version, 1, 4) || '.' || CAST(row_num AS TEXT)
      FROM (
        SELECT id,
               ROW_NUMBER() OVER (
                 PARTITION BY organization_id, name, substr(version, 1, 4)
                 ORDER BY version
               ) AS row_num
        FROM libraries
        WHERE version IS NOT NULL
      ) ranked
      WHERE ranked.id = libraries.id
    )
    WHERE version IS NOT NULL
    """)
  end

  def down do
    # Not reversible — original month info is lost
    :ok
  end
end
