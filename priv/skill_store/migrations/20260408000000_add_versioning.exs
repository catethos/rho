defmodule Rho.SkillStore.Repo.Migrations.AddVersioning do
  use Ecto.Migration
  import Ecto.Query

  def change do
    alter table(:frameworks) do
      add(:role_name, :string)
      add(:year, :integer)
      add(:version, :integer)
      add(:is_default, :boolean)
      add(:description, :string)
    end

    create(
      unique_index(:frameworks, [:company_id, :role_name, :year, :version],
        name: :frameworks_company_role_year_version_index,
        where: "type = 'company'"
      )
    )

    # Backfill existing company frameworks
    flush()

    repo = Rho.SkillStore.Repo

    frameworks =
      repo.all(
        from(f in "frameworks",
          where: f.type == "company",
          select: %{id: f.id, name: f.name, inserted_at: f.inserted_at}
        )
      )

    for fw <- frameworks do
      role_name =
        fw.name
        |> String.replace(~r/_?\d{4}/, "")
        |> String.replace("_", " ")
        |> String.split()
        |> Enum.map(&String.capitalize/1)
        |> Enum.join(" ")
        |> String.trim()

      year =
        case Regex.run(~r/(\d{4})/, fw.name) do
          [_, y] ->
            String.to_integer(y)

          _ ->
            case fw.inserted_at do
              <<y::binary-size(4), _::binary>> -> String.to_integer(y)
              _ -> 2026
            end
        end

      slug =
        role_name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")

      new_name = "#{slug}_#{year}_v1"

      repo.query!(
        "UPDATE frameworks SET role_name = ?1, year = ?2, version = 1, is_default = 1, name = ?3 WHERE id = ?4",
        [role_name, year, new_name, fw.id]
      )
    end
  end
end
