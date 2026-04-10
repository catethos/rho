defmodule RhoWeb.LensChartComponents do
  @moduledoc """
  Server-side SVG chart components for the lens dashboard.
  Renders matrix, scatter, and bar charts from plain map data.
  """
  use Phoenix.Component

  # ── Summary Cards ──────────────────────────────────────────────────────

  attr(:summary, :map, required: true)
  attr(:lens, :map, default: nil)

  def lens_summary_cards(assigns) do
    ~H"""
    <div class="lens-summary-cards">
      <div class="lens-summary-card">
        <div class="lens-summary-value"><%= @summary.total %></div>
        <div class="lens-summary-label">Scored</div>
      </div>
      <%= for {label, count} <- @summary.by_classification || %{} do %>
        <div class="lens-summary-card">
          <div class="lens-summary-value"><%= count %></div>
          <div class="lens-summary-label"><%= label %></div>
        </div>
      <% end %>
      <%= for avg <- @summary.axis_averages || [] do %>
        <div class="lens-summary-card">
          <div class="lens-summary-value"><%= avg[:average] || avg["average"] %></div>
          <div class="lens-summary-label">Avg <%= avg[:short_name] || avg["short_name"] %></div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── 2-Axis Matrix ──────────────────────────────────────────────────────

  attr(:lens, :map, required: true)
  attr(:scores, :list, required: true)

  def lens_matrix_component(assigns) do
    lens = assigns.lens

    axes =
      (lens[:axes] || lens["axes"] || []) |> Enum.sort_by(&(&1[:sort_order] || &1["sort_order"]))

    classifications = lens[:classifications] || lens["classifications"] || []

    {x_axis, y_axis} =
      case axes do
        [a0, a1 | _] -> {a0, a1}
        _ -> {nil, nil}
      end

    x_bands = if x_axis, do: x_axis[:band_labels] || x_axis["band_labels"] || [], else: []
    y_bands = if y_axis, do: y_axis[:band_labels] || y_axis["band_labels"] || [], else: []

    # Build classification lookup: {axis_0_band, axis_1_band} => classification
    class_lookup =
      Map.new(classifications, fn c ->
        b0 = c[:axis_0_band] || c["axis_0_band"]
        b1 = c[:axis_1_band] || c["axis_1_band"]
        {{b0, b1}, c}
      end)

    # Count scores per cell
    score_counts =
      assigns.scores
      |> Enum.reduce(%{}, fn score, acc ->
        score_axes = score[:axes] || score["axes"] || []

        case Enum.sort_by(score_axes, &(&1[:sort_order] || &1["sort_order"])) do
          [a0, a1 | _] ->
            b0 = a0[:band] || a0["band"]
            b1 = a1[:band] || a1["band"]
            Map.update(acc, {b0, b1}, 1, &(&1 + 1))

          _ ->
            acc
        end
      end)

    assigns =
      assigns
      |> assign(:x_axis, x_axis)
      |> assign(:y_axis, y_axis)
      |> assign(:x_bands, x_bands)
      |> assign(:y_bands, y_bands)
      |> assign(:class_lookup, class_lookup)
      |> assign(:score_counts, score_counts)

    ~H"""
    <div class="lens-matrix">
      <div class="lens-matrix-ylabel"><%= axis_name(@y_axis) %></div>
      <div class="lens-matrix-grid" style={"grid-template-columns: auto repeat(#{length(@x_bands)}, 1fr); grid-template-rows: repeat(#{length(@y_bands)}, 1fr) auto;"}>
        <%!-- Cells: y descending (high at top), x ascending (low at left) --%>
        <%= for {y_label, y_idx} <- @y_bands |> Enum.with_index() |> Enum.reverse() do %>
          <div class="lens-matrix-row-label"><%= y_label %></div>
          <%= for {_x_label, x_idx} <- Enum.with_index(@x_bands) do %>
            <% classification = Map.get(@class_lookup, {x_idx, y_idx}) %>
            <% count = Map.get(@score_counts, {x_idx, y_idx}, 0) %>
            <% color = if classification, do: classification[:color] || classification["color"], else: "#e5e5e5" %>
            <% label = if classification, do: classification[:label] || classification["label"], else: "" %>
            <div
              class="lens-matrix-cell"
              style={"background: #{color}18; border-color: #{color}40;"}
              title={"#{label}: #{count} roles"}
            >
              <span class="lens-matrix-cell-label" style={"color: #{color};"}><%= label %></span>
              <span :if={count > 0} class="lens-matrix-cell-count"><%= count %></span>
            </div>
          <% end %>
        <% end %>
        <%!-- X-axis labels --%>
        <div></div>
        <%= for x_label <- @x_bands do %>
          <div class="lens-matrix-col-label"><%= x_label %></div>
        <% end %>
      </div>
      <div class="lens-matrix-xlabel"><%= axis_name(@x_axis) %></div>
    </div>
    """
  end

  # ── 2-Axis Scatter ─────────────────────────────────────────────────────

  attr(:lens, :map, required: true)
  attr(:scores, :list, required: true)
  attr(:width, :integer, default: 400)
  attr(:height, :integer, default: 300)

  def lens_scatter_component(assigns) do
    margin = 40
    plot_w = assigns.width - margin * 2
    plot_h = assigns.height - margin * 2

    points =
      Enum.map(assigns.scores, fn score ->
        score_axes =
          (score[:axes] || score["axes"] || [])
          |> Enum.sort_by(&(&1[:sort_order] || &1["sort_order"]))

        {x_val, y_val} =
          case score_axes do
            [a0, a1 | _] ->
              {a0[:composite] || a0["composite"] || 0, a1[:composite] || a1["composite"] || 0}

            _ ->
              {0, 0}
          end

        target = score[:target] || score["target"] || %{}
        classification = score[:classification] || score["classification"]
        score_id = score[:score_id] || score["score_id"]

        cx = margin + x_val / 100 * plot_w
        cy = margin + (100 - y_val) / 100 * plot_h

        %{cx: cx, cy: cy, classification: classification, target: target, score_id: score_id}
      end)

    lens = assigns.lens

    axes =
      (lens[:axes] || lens["axes"] || []) |> Enum.sort_by(&(&1[:sort_order] || &1["sort_order"]))

    {x_axis, y_axis} =
      case axes do
        [a0, a1 | _] -> {a0, a1}
        _ -> {nil, nil}
      end

    assigns =
      assigns
      |> assign(:margin, margin)
      |> assign(:plot_w, plot_w)
      |> assign(:plot_h, plot_h)
      |> assign(:points, points)
      |> assign(:x_axis, x_axis)
      |> assign(:y_axis, y_axis)

    ~H"""
    <svg class="lens-scatter-svg" viewBox={"0 0 #{@width} #{@height}"} xmlns="http://www.w3.org/2000/svg">
      <%!-- Grid --%>
      <rect x={@margin} y={@margin} width={@plot_w} height={@plot_h} fill="none" stroke="var(--border)" stroke-width="1" />
      <%!-- Axis labels --%>
      <text x={@margin + @plot_w / 2} y={@height - 4} text-anchor="middle" fill="var(--text-secondary)" font-size="11"><%= axis_name(@x_axis) %></text>
      <text x={10} y={@margin + @plot_h / 2} text-anchor="middle" fill="var(--text-secondary)" font-size="11" transform={"rotate(-90, 10, #{@margin + @plot_h / 2})"}><%= axis_name(@y_axis) %></text>
      <%!-- Threshold lines --%>
      <%= for t <- axis_thresholds(@x_axis) do %>
        <line x1={@margin + t / 100 * @plot_w} y1={@margin} x2={@margin + t / 100 * @plot_w} y2={@margin + @plot_h} stroke="var(--border)" stroke-dasharray="4 2" />
      <% end %>
      <%= for t <- axis_thresholds(@y_axis) do %>
        <line x1={@margin} y1={@margin + (100 - t) / 100 * @plot_h} x2={@margin + @plot_w} y2={@margin + (100 - t) / 100 * @plot_h} stroke="var(--border)" stroke-dasharray="4 2" />
      <% end %>
      <%!-- Points --%>
      <%= for pt <- @points do %>
        <circle
          cx={pt.cx}
          cy={pt.cy}
          r="5"
          fill={classification_color(pt.classification)}
          opacity="0.8"
          phx-click="select_lens_score"
          phx-value-score-id={pt.score_id}
          style="cursor: pointer;"
        >
          <title><%= target_label(pt.target) %> — <%= pt.classification %></title>
        </circle>
      <% end %>
    </svg>
    """
  end

  # ── 1-Axis Bar Chart ───────────────────────────────────────────────────

  attr(:lens, :map, required: true)
  attr(:scores, :list, required: true)
  attr(:width, :integer, default: 400)
  attr(:height, :integer, default: 300)

  def lens_bar_chart_component(assigns) do
    margin = %{top: 20, right: 20, bottom: 30, left: 120}
    plot_w = assigns.width - margin.left - margin.right
    plot_h = assigns.height - margin.top - margin.bottom

    sorted_scores =
      assigns.scores
      |> Enum.map(fn score ->
        score_axes = score[:axes] || score["axes"] || []

        composite =
          case score_axes do
            [a | _] -> a[:composite] || a["composite"] || 0
            _ -> 0
          end

        target = score[:target] || score["target"] || %{}
        classification = score[:classification] || score["classification"]
        score_id = score[:score_id] || score["score_id"]

        %{
          composite: composite,
          target: target,
          classification: classification,
          score_id: score_id
        }
      end)
      |> Enum.sort_by(& &1.composite, :desc)

    bar_height =
      if sorted_scores == [], do: 0, else: min(24, plot_h / max(length(sorted_scores), 1))

    gap = 4

    bars =
      sorted_scores
      |> Enum.with_index()
      |> Enum.map(fn {s, idx} ->
        y = margin.top + idx * (bar_height + gap)
        w = s.composite / 100 * plot_w
        Map.merge(s, %{y: y, bar_width: w, bar_height: bar_height})
      end)

    assigns =
      assigns
      |> assign(:margin, margin)
      |> assign(:plot_w, plot_w)
      |> assign(:bars, bars)

    ~H"""
    <svg class="lens-bar-svg" viewBox={"0 0 #{@width} #{@height}"} xmlns="http://www.w3.org/2000/svg">
      <%= for bar <- @bars do %>
        <text x={@margin.left - 6} y={bar.y + bar.bar_height / 2 + 4} text-anchor="end" fill="var(--text-secondary)" font-size="10"><%= target_label(bar.target) |> String.slice(0..18) %></text>
        <rect
          x={@margin.left}
          y={bar.y}
          width={max(bar.bar_width, 2)}
          height={bar.bar_height}
          rx="3"
          fill={classification_color(bar.classification)}
          opacity="0.75"
          phx-click="select_lens_score"
          phx-value-score-id={bar.score_id}
          style="cursor: pointer;"
        >
          <title><%= target_label(bar.target) %> — <%= bar.composite %></title>
        </rect>
        <text x={@margin.left + bar.bar_width + 4} y={bar.y + bar.bar_height / 2 + 4} fill="var(--text-secondary)" font-size="10"><%= Float.round(bar.composite / 1, 1) %></text>
      <% end %>
    </svg>
    """
  end

  # ── Detail Panel ───────────────────────────────────────────────────────

  attr(:detail, :map, default: nil)
  attr(:on_close, :string, default: "close_lens_detail")

  def lens_detail_panel(assigns) do
    ~H"""
    <div :if={@detail} class="lens-detail-panel">
      <div class="lens-detail-header">
        <h3 class="lens-detail-title"><%= target_label(@detail[:target] || @detail["target"]) %></h3>
        <button class="lens-detail-close" phx-click={@on_close}>×</button>
      </div>
      <div class="lens-detail-meta">
        <span class="lens-detail-classification"><%= @detail[:classification] || @detail["classification"] %></span>
        <span class="lens-detail-method"><%= @detail[:scoring_method] || @detail["scoring_method"] %></span>
      </div>
      <div class="lens-detail-axes">
        <%= for axis <- @detail[:axes] || @detail["axes"] || [] do %>
          <div class="lens-detail-axis">
            <div class="lens-detail-axis-header">
              <span class="lens-detail-axis-name"><%= axis[:axis_name] || axis["axis_name"] %></span>
              <span class="lens-detail-axis-composite"><%= axis[:composite] || axis["composite"] %></span>
              <span class="lens-detail-axis-band"><%= axis[:band_label] || axis["band_label"] %></span>
            </div>
            <div class="lens-detail-variables">
              <%= for var <- axis[:variables] || axis["variables"] || [] do %>
                <div class="lens-detail-var">
                  <div class="lens-detail-var-header">
                    <span class="lens-detail-var-name"><%= var[:name] || var["name"] %></span>
                    <span class="lens-detail-var-score"><%= var[:raw_score] || var["raw_score"] %> → <%= var[:weighted_score] || var["weighted_score"] %></span>
                  </div>
                  <div :if={var[:rationale] || var["rationale"]} class="lens-detail-var-rationale">
                    <%= var[:rationale] || var["rationale"] %>
                  </div>
                  <div class="lens-detail-var-bar">
                    <div class="lens-detail-var-bar-fill" style={"width: #{var[:raw_score] || var["raw_score"] || 0}%;"}></div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp axis_name(nil), do: ""
  defp axis_name(axis), do: axis[:name] || axis["name"] || ""

  defp axis_thresholds(nil), do: []
  defp axis_thresholds(axis), do: axis[:band_thresholds] || axis["band_thresholds"] || []

  defp target_label(nil), do: "—"

  defp target_label(target) when is_map(target) do
    target[:name] || target["name"] || target[:label] || target["label"] ||
      "#{target[:type] || target["type"]} ##{target[:id] || target["id"]}"
  end

  defp target_label(_), do: "—"

  @classification_colors %{
    "Transform" => "#3B82F6",
    "Restructure" => "#EF4444",
    "Leverage" => "#10B981",
    "Maintain" => "#6B7280",
    "Monitor" => "#F59E0B"
  }

  defp classification_color(nil), do: "var(--teal)"
  defp classification_color(label), do: Map.get(@classification_colors, label, "var(--teal)")
end
