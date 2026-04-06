defmodule Rho.SkillStore.Company do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "companies" do
    field(:name, :string)
    has_many(:frameworks, Rho.SkillStore.Framework, foreign_key: :company_id)
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(company, attrs) do
    company
    |> cast(attrs, [:id, :name])
    |> validate_required([:id, :name])
    |> unique_constraint(:id, name: :companies_pkey)
  end
end
