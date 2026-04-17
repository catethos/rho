defmodule RhoFrameworks.Repo.Migrations.AddLensScoreIndexes do
  use Ecto.Migration

  def change do
    create(index(:lens_scores, [:lens_id, :role_profile_id, :skill_id]))
    create(index(:lens_axis_scores, [:lens_score_id]))
    create(index(:lens_variable_scores, [:axis_score_id]))
  end
end
