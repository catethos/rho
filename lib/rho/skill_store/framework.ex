defmodule Rho.SkillStore.Framework do
  use Ecto.Schema
  import Ecto.Changeset

  schema "frameworks" do
    field(:name, :string)
    field(:type, :string, default: "company")
    field(:source, :string)
    field(:row_count, :integer, default: 0)
    field(:skill_count, :integer, default: 0)

    belongs_to(:company, Rho.SkillStore.Company, type: :string)
    has_many(:rows, Rho.SkillStore.FrameworkRow)

    timestamps(type: :utc_datetime)
  end

  def changeset(framework, attrs) do
    framework
    |> cast(attrs, [:name, :type, :company_id, :source, :row_count, :skill_count])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, ["industry", "company"])
    |> foreign_key_constraint(:company_id)
  end
end
