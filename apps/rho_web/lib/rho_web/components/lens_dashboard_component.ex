defmodule RhoWeb.LensDashboardComponent do
  @moduledoc """
  LiveComponent for the lens dashboard workspace panel.

  Receives projection state from `LensDashboardProjection` and selects
  the appropriate chart sub-component based on the lens's axis count:
  - 1 axis → bar chart
  - 2 axes → matrix + scatter
  - 3+ axes → placeholder (radar chart future)
  """
  use Phoenix.LiveComponent

  import RhoWeb.LensChartComponents

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    dashboard_state = socket.assigns[:dashboard_state] || %{}
    lens = dashboard_state[:lens]

    axis_count =
      if lens do
        axes = lens[:axes] || lens["axes"] || []
        length(axes)
      else
        0
      end

    scores = Map.values(dashboard_state[:scores] || %{})
    summary = dashboard_state[:summary] || %{total: 0, by_classification: %{}, axis_averages: []}
    selected_score_id = dashboard_state[:selected_score_id]

    socket =
      socket
      |> assign(:lens, lens)
      |> assign(:axis_count, axis_count)
      |> assign(:scores, scores)
      |> assign(:summary, summary)
      |> assign(:selected_score_id, selected_score_id)
      |> assign(:detail, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_lens_score", %{"score-id" => score_id_str}, socket) do
    score_id = parse_id(score_id_str)
    dashboard_state = socket.assigns[:dashboard_state] || %{}
    scores = dashboard_state[:scores] || %{}
    score = Map.get(scores, score_id)

    # Request full detail from the parent via send
    if score do
      send(self(), {:lens_detail_request, score_id})
    end

    {:noreply, assign(socket, :selected_score_id, score_id)}
  end

  def handle_event("close_lens_detail", _params, socket) do
    {:noreply, assign(socket, :selected_score_id, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={"lens-dashboard #{@class}"}>
      <%= if @lens do %>
        <div class="lens-dashboard-header">
          <h2 class="lens-dashboard-title"><%= @lens[:name] || @lens["name"] %></h2>
          <p class="lens-dashboard-desc"><%= @lens[:description] || @lens["description"] %></p>
        </div>

        <.lens_summary_cards summary={@summary} lens={@lens} />

        <div class="lens-dashboard-charts">
          <%= case @axis_count do %>
            <% 2 -> %>
              <div class="lens-chart-pair">
                <.lens_matrix_component lens={@lens} scores={@scores} />
                <.lens_scatter_component lens={@lens} scores={@scores} />
              </div>
            <% 1 -> %>
              <.lens_bar_chart_component lens={@lens} scores={@scores} />
            <% _ -> %>
              <div class="lens-chart-placeholder">
                <p>Select or score roles to populate the dashboard.</p>
              </div>
          <% end %>
        </div>

        <.lens_detail_panel detail={@detail} />
      <% else %>
        <div class="lens-dashboard-empty">
          <div class="empty-state">
            <div class="empty-state-icon">&#x1F50D;</div>
            <h2 class="empty-state-title">Lens Dashboard</h2>
            <p class="empty-state-hint">Score roles with a lens to see results here</p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {id, ""} -> id
      _ -> str
    end
  end

  defp parse_id(id), do: id
end
