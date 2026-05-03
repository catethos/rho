defmodule RhoFrameworks.Repo.Migrations.CreateSystemOrganization do
  use Ecto.Migration

  @moduledoc """
  Seeds the `system` organization that owns public libraries and public role
  profiles (e.g. the imported ESCO classification).

  Idempotent: re-running is a no-op via `ON CONFLICT DO NOTHING` on the unique
  `slug` index. The System org has no memberships.
  """

  def up do
    execute("""
    INSERT INTO organizations (id, name, slug, personal, inserted_at, updated_at)
    VALUES (gen_random_uuid(), 'System', 'system', false, NOW(), NOW())
    ON CONFLICT (slug) DO NOTHING
    """)
  end

  def down do
    execute("DELETE FROM organizations WHERE slug = 'system'")
  end
end
