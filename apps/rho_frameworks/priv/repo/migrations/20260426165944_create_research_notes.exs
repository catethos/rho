defmodule RhoFrameworks.Repo.Migrations.CreateResearchNotes do
  use Ecto.Migration

  def change do
    create table(:research_notes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :library_id,
        references(:libraries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:source, :string, null: false)
      add(:fact, :text, null: false)
      add(:tag, :string)

      # 'user' | 'agent' — preserves whether a note came from the LLM
      # researcher or was hand-added in the panel.
      add(:inserted_by, :string, null: false, default: "agent")

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(index(:research_notes, [:library_id]))
  end
end
