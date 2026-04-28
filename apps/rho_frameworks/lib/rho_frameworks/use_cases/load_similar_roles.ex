defmodule RhoFrameworks.UseCases.LoadSimilarRoles do
  @moduledoc """
  Find role profiles in the org similar to the framework being created.

  Builds a similarity query from intake fields (`name`, `domain`,
  `target_roles`) and ranks candidates via `RhoFrameworks.Roles`.

  Returns `{:ok, %{matches: [...], skip_reason: nil | binary}}`. Empty
  matches carry a `skip_reason` so the wizard's select-step can
  short-circuit without re-deriving "did we find anything?" downstream.
  """

  @behaviour RhoFrameworks.UseCase

  alias RhoFrameworks.{Roles, Scope}

  @default_limit 5

  @impl true
  def describe do
    %{
      id: :load_similar_roles,
      label: "Find similar roles",
      cost_hint: :cheap,
      doc: "Find existing role profiles similar to the framework being built."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    limit = Map.get(input, :limit, @default_limit)
    query = build_query(input)

    case Roles.find_similar_roles(scope.organization_id, query, limit: limit) do
      [] ->
        {:ok, %{matches: [], skip_reason: "No similar roles found — continuing to generation."}}

      roles ->
        {:ok, %{matches: roles, skip_reason: nil}}
    end
  end

  defp build_query(input) do
    [Map.get(input, :name), Map.get(input, :domain), Map.get(input, :target_roles)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
  end
end
