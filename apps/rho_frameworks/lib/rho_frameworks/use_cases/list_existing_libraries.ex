defmodule RhoFrameworks.UseCases.ListExistingLibraries do
  @moduledoc """
  Drive the `:pick_existing_library` `:select` step on the
  `extend_existing` branch of `RhoFrameworks.Flows.CreateFramework`.

  Returns the org's mutable libraries (immutable templates excluded — you
  extend by deriving from a draft, not by editing a frozen template) in
  the same `%{matches: [...], skip_reason: nil | binary}` shape
  `LoadSimilarRoles` returns, so `FlowLive`'s `:select` step renders them
  with `display_fields: %{title: :name, subtitle: :skill_count, detail: :updated_at}`.

  Empty results return a `:skip_reason` so the `:no_existing_libraries`
  guard can bounce back to `:choose_starting_point` cleanly.
  """

  @behaviour RhoFrameworks.UseCase

  alias RhoFrameworks.{Library, Scope}

  @impl true
  def describe do
    %{
      id: :list_existing_libraries,
      label: "List existing frameworks",
      cost_hint: :instant,
      doc: "List the org's existing draft frameworks for the extend path."
    }
  end

  @impl true
  def run(_input, %Scope{organization_id: org_id}) do
    case Library.list_libraries(org_id, exclude_immutable: true, include_public: false) do
      [] ->
        {:ok,
         %{
           matches: [],
           skip_reason:
             "No existing frameworks found in this org — pick a different starting point."
         }}

      libraries ->
        {:ok, %{matches: Enum.map(libraries, &to_match/1), skip_reason: nil}}
    end
  end

  defp to_match(lib) do
    %{
      id: lib.id,
      name: lib.name,
      skill_count: lib.skill_count,
      updated_at: format_updated(lib.updated_at)
    }
  end

  defp format_updated(%DateTime{} = dt), do: DateTime.to_date(dt) |> Date.to_string()
  defp format_updated(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt) |> Date.to_string()
  defp format_updated(_), do: ""
end
