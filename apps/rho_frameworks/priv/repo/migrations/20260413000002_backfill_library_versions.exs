defmodule RhoFrameworks.Repo.Migrations.BackfillLibraryVersions do
  use Ecto.Migration

  def up do
    # Backfill existing libraries with a CalVer version derived from updated_at.
    # Immutable (standard template) libraries are skipped — they use source_key identity.
    execute("""
    UPDATE libraries
    SET version = strftime('%Y.%m', updated_at),
        published_at = updated_at
    WHERE version IS NULL
      AND immutable = false
    """)
  end

  def down do
    execute("""
    UPDATE libraries
    SET version = NULL,
        published_at = NULL
    WHERE immutable = false
    """)
  end
end
