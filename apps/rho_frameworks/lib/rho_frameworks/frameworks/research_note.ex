defmodule RhoFrameworks.Frameworks.ResearchNote do
  @moduledoc """
  Persisted research note attached to a library.

  Written when a framework is saved (`Workbench.save_framework/3`) — the
  pinned rows from the session's `research_notes` named table are
  archived here so a future library detail view can show "what informed
  this framework". Unpinned findings are intentionally discarded; this
  table is the curated subset the user endorsed.

  Immutable: only `inserted_at` (no `updated_at`). To revise a note,
  delete and re-insert.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "research_notes" do
    field(:source, :string)
    field(:fact, :string)
    field(:tag, :string)
    field(:inserted_by, :string, default: "agent")

    belongs_to(:library, RhoFrameworks.Frameworks.Library)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @permitted [:library_id, :source, :fact, :tag, :inserted_by]
  @required [:library_id, :source, :fact]

  def changeset(note, attrs) do
    note
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_length(:source, min: 1, max: 2000)
    |> validate_length(:fact, min: 1)
    |> validate_inclusion(:inserted_by, ["user", "agent"])
    |> foreign_key_constraint(:library_id)
  end
end
