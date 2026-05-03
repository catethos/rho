defmodule RhoFrameworks.Repo.Migrations.AddSkillEmbeddings do
  use Ecto.Migration

  def change do
    alter table(:skills) do
      add(:embedding, :vector, size: 384)
      add(:embedding_text_hash, :binary)
      add(:embedded_at, :utc_datetime_usec)
    end

    execute(
      "CREATE INDEX skills_embedding_idx ON skills USING hnsw (embedding vector_cosine_ops)",
      "DROP INDEX skills_embedding_idx"
    )
  end
end
