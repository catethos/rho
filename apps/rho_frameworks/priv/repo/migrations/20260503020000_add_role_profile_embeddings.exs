defmodule RhoFrameworks.Repo.Migrations.AddRoleProfileEmbeddings do
  use Ecto.Migration

  def change do
    alter table(:role_profiles) do
      add(:embedding, :vector, size: 384)
      add(:embedding_text_hash, :binary)
      add(:embedded_at, :utc_datetime_usec)
    end

    execute(
      "CREATE INDEX role_profiles_embedding_idx ON role_profiles USING hnsw (embedding vector_cosine_ops)",
      "DROP INDEX role_profiles_embedding_idx"
    )
  end
end
