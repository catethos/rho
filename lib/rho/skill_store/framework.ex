defmodule Rho.SkillStore.Framework do
  use Ecto.Schema
  import Ecto.Changeset

  schema "frameworks" do
    field(:name, :string)
    field(:type, :string, default: "company")
    field(:source, :string)
    field(:row_count, :integer, default: 0)
    field(:skill_count, :integer, default: 0)
    field(:role_name, :string)
    field(:year, :integer)
    field(:version, :integer)
    field(:is_default, :boolean)
    field(:description, :string)

    belongs_to(:company, Rho.SkillStore.Company, type: :string)
    has_many(:rows, Rho.SkillStore.FrameworkRow)

    timestamps(type: :utc_datetime)
  end

  def changeset(framework, attrs) do
    framework
    |> cast(attrs, [
      :name,
      :type,
      :company_id,
      :source,
      :row_count,
      :skill_count,
      :role_name,
      :year,
      :version,
      :is_default,
      :description
    ])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, ["industry", "company"])
    |> maybe_validate_company_fields()
    |> foreign_key_constraint(:company_id)
  end

  defp maybe_validate_company_fields(changeset) do
    type = get_field(changeset, :type)
    role_name = get_change(changeset, :role_name)

    # Only validate new versioning fields when they're explicitly being set
    # This preserves backwards compat with save_framework/1 (no versioning fields)
    if type == "company" and role_name != nil do
      changeset
      |> validate_required([:role_name, :year, :version])
    else
      changeset
    end
  end
end
