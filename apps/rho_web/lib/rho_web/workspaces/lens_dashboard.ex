defmodule RhoWeb.Workspaces.LensDashboard do
  @moduledoc """
  Workspace metadata for the Lens Dashboard panel.
  """
  use RhoWeb.Workspace

  @impl true
  def key, do: :lens_dashboard

  @impl true
  def label, do: "Lens Dashboard"

  @impl true
  def icon, do: "chart"

  @impl true
  def auto_open?, do: true

  @impl true
  def default_surface, do: :overlay

  @impl true
  def projection, do: RhoWeb.Projections.LensDashboardProjection

  @impl true
  def component, do: RhoWeb.LensDashboardComponent

  @impl true
  def component_assigns(ws_state, shared) do
    %{
      dashboard_state: ws_state,
      session_id: shared.session_id
    }
  end

  @impl true
  def handle_info({:lens_detail_request, score_id}, ws_state, context) do
    org_id = context[:organization_id]

    detail =
      if org_id do
        try do
          RhoFrameworks.Lenses.score_detail(score_id)
        rescue
          _ -> nil
        end
      end

    if detail do
      {:noreply, Map.put(ws_state || %{}, :detail, detail)}
    else
      {:noreply, ws_state}
    end
  end

  def handle_info(_message, _ws_state, _context), do: :skip
end
