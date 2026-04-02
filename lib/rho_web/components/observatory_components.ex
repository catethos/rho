defmodule RhoWeb.ObservatoryComponents do
  @moduledoc """
  UI components for the multi-agent Observatory.
  Discussion-centric view: chat bubbles, tool annotations, timeline markers.
  """

  use Phoenix.Component

  # --- Discussion timeline ---

  attr :discussion, :list, required: true
  attr :agents, :map, required: true

  def discussion_timeline(assigns) do
    ~H"""
    <div class="disc-timeline">
      <div :if={@discussion == []} class="disc-empty">
        Waiting for agent activity...
      </div>
      <div :for={entry <- Enum.reverse(@discussion)} class="disc-entry-wrap">
        <.disc_entry entry={entry} />
      </div>
    </div>
    """
  end

  defp disc_entry(%{entry: %{type: :message}} = assigns) do
    ~H"""
    <div class={"disc-message disc-role-#{role_slug(@entry.agent_name)}"}>
      <div class="disc-message-header">
        <span class={"disc-avatar disc-avatar-#{role_slug(@entry.agent_name)}"}><%= avatar(@entry.agent_name) %></span>
        <span class="disc-author"><%= format_name(@entry.agent_name) %></span>
        <span :if={@entry.meta[:to] && @entry.meta[:to] != :all} class="disc-target">
          &rarr; <%= format_name(@entry.meta[:to]) %>
        </span>
        <span :if={@entry.meta[:to] == :all} class="disc-target disc-broadcast">&rarr; all</span>
      </div>
      <div class="disc-message-body" phx-hook="Markdown" id={"msg-#{@entry.id}"} data-md={@entry.content}>
      </div>
    </div>
    """
  end

  defp disc_entry(%{entry: %{type: :thinking}} = assigns) do
    ~H"""
    <div class={"disc-thinking disc-role-#{role_slug(@entry.agent_name)}"}>
      <div class="disc-thinking-header">
        <span class={"disc-avatar disc-avatar-#{role_slug(@entry.agent_name)} disc-avatar-dim"}><%= avatar(@entry.agent_name) %></span>
        <span class="disc-author-dim"><%= format_name(@entry.agent_name) %></span>
        <span class="disc-thinking-label">thinking</span>
      </div>
      <div class="disc-thinking-body">
        <%= truncate(@entry.content, 400) %>
      </div>
    </div>
    """
  end

  defp disc_entry(%{entry: %{type: :tool_use}} = assigns) do
    ~H"""
    <div class={"disc-tool disc-role-#{role_slug(@entry.agent_name)}"}>
      <span class="disc-tool-icon">&#9881;</span>
      <span class="disc-tool-agent"><%= format_name(@entry.agent_name) %></span>
      <span class="disc-tool-name"><%= @entry.content %></span>
      <span :if={@entry.meta[:args]} class="disc-tool-args"><%= @entry.meta[:args] %></span>
    </div>
    """
  end

  defp disc_entry(%{entry: %{type: :tool_result}} = assigns) do
    ~H"""
    <div class={"disc-tool-result #{if @entry.meta[:status] != :ok, do: "disc-tool-error"}"}>
      <span class="disc-tool-result-status"><%= if @entry.meta[:status] == :ok, do: "✓", else: "✗" %></span>
      <span class="disc-tool-result-text"><%= truncate(@entry.content, 200) %></span>
    </div>
    """
  end

  defp disc_entry(%{entry: %{type: :agent_event}} = assigns) do
    ~H"""
    <div class="disc-event">
      <span class={"disc-event-dot disc-avatar-#{role_slug(@entry.agent_name)}"}></span>
      <span class="disc-event-text">
        <strong><%= format_name(@entry.agent_name) %></strong> <%= @entry.content %>
      </span>
    </div>
    """
  end

  defp disc_entry(%{entry: %{type: :marker}} = assigns) do
    ~H"""
    <div class={"disc-marker #{if @entry.meta[:kind] == :complete, do: "disc-marker-complete"}"}>
      <span class="disc-marker-line"></span>
      <span class="disc-marker-text"><%= @entry.content %></span>
      <span class="disc-marker-line"></span>
    </div>
    """
  end

  defp disc_entry(%{entry: %{type: :turn_end}} = assigns) do
    ~H"""
    <div class={"disc-message disc-role-#{role_slug(@entry.agent_name)}"}>
      <div class="disc-message-header">
        <span class={"disc-avatar disc-avatar-#{role_slug(@entry.agent_name)}"}><%= avatar(@entry.agent_name) %></span>
        <span class="disc-author"><%= format_name(@entry.agent_name) %></span>
        <span class="disc-thinking-label">final response</span>
      </div>
      <div class="disc-message-body" phx-hook="Markdown" id={"turn-end-#{@entry.id}"} data-md={truncate(@entry.content, 2000)}>
      </div>
    </div>
    """
  end

  # Fallback
  defp disc_entry(assigns) do
    ~H"""
    <div class="disc-event">
      <span class="disc-event-text disc-muted"><%= @entry.type %>: <%= truncate(to_string(@entry.content), 100) %></span>
    </div>
    """
  end

  # --- Interaction graph (sidebar) ---

  attr :agents, :map, required: true
  attr :edges, :map, required: true
  attr :recent_edges, :list, required: true

  def interaction_graph(assigns) do
    agent_list =
      assigns.agents
      |> Enum.filter(fn {_id, a} -> a[:agent_name] end)
      |> Enum.sort_by(fn {id, _} -> id end)

    n = length(agent_list)
    cx = 120
    cy = 110
    r = if n <= 3, do: 60, else: 75

    # Position agents in a circle
    positions =
      agent_list
      |> Enum.with_index()
      |> Enum.map(fn {{id, agent}, i} ->
        angle = -:math.pi() / 2 + 2 * :math.pi() * i / max(n, 1)
        x = cx + r * :math.cos(angle)
        y = cy + r * :math.sin(angle)
        {id, agent, x, y}
      end)

    pos_map = Map.new(positions, fn {id, _a, x, y} -> {id, {x, y}} end)

    # Build edge data with positions
    max_count = assigns.edges |> Map.values() |> Enum.max(fn -> 1 end)

    edge_data =
      assigns.edges
      |> Enum.filter(fn {{from, to}, _} -> Map.has_key?(pos_map, from) and Map.has_key?(pos_map, to) end)
      |> Enum.with_index()
      |> Enum.map(fn {{{from, to}, count}, idx} ->
        {fx, fy} = pos_map[from]
        {tx, ty} = pos_map[to]
        thickness = 1.5 + 3 * count / max(max_count, 1)
        from_agent = assigns.agents[from]
        # Pre-compute line endpoints offset by node radius
        dx = tx - fx
        dy = ty - fy
        len = :math.sqrt(dx * dx + dy * dy)
        nx = dx / max(len, 1)
        ny = dy / max(len, 1)
        %{
          x1: fx + nx * 18, y1: fy + ny * 18,
          x2: tx - nx * 18, y2: ty - ny * 18,
          fx: fx, fy: fy, tx: tx, ty: ty,
          count: count, thickness: thickness, idx: idx,
          role: role_slug((from_agent || %{})[:agent_name])
        }
      end)

    # Recent edges for live particle animation
    now = System.monotonic_time(:millisecond)
    recent =
      assigns.recent_edges
      |> Enum.filter(fn {from, to, _t} -> Map.has_key?(pos_map, from) and Map.has_key?(pos_map, to) end)
      |> Enum.filter(fn {_, _, t} -> now - t < 3000 end)
      |> Enum.with_index()
      |> Enum.map(fn {{from, to, _t}, idx} ->
        {fx, fy} = pos_map[from]
        {tx, ty} = pos_map[to]
        from_agent = assigns.agents[from]
        %{fx: fx, fy: fy, tx: tx, ty: ty, idx: idx, role: role_slug((from_agent || %{})[:agent_name])}
      end)

    # For historical sessions with no recent edges, use looping ambient particles on all edges
    has_live_particles = recent != []

    assigns =
      assigns
      |> Phoenix.Component.assign(:positions, positions)
      |> Phoenix.Component.assign(:edge_data, edge_data)
      |> Phoenix.Component.assign(:recent, recent)
      |> Phoenix.Component.assign(:has_live_particles, has_live_particles)

    ~H"""
    <div class="igraph-wrap" id="interaction-graph" phx-hook="InteractionGraph">
      <svg viewBox="0 0 240 220" class="igraph-svg">
        <defs>
          <marker id="arrow" markerWidth="6" markerHeight="4" refX="5" refY="2" orient="auto">
            <path d="M0,0 L6,2 L0,4" fill="var(--text-muted)" opacity="0.6" />
          </marker>
        </defs>

        <!-- Edges with animated dash for flow direction -->
        <%= for e <- @edge_data do %>
          <line
            x1={e.x1} y1={e.y1}
            x2={e.x2} y2={e.y2}
            class={"igraph-edge igraph-edge-#{e.role}"}
            stroke-width={e.thickness}
            marker-end="url(#arrow)"
          />
        <% end %>

        <!-- Ambient looping particles on edges (shown when no live particles) -->
        <%= if !@has_live_particles do %>
          <%= for e <- @edge_data do %>
            <circle r="2.5" class={"igraph-particle igraph-ambient igraph-particle-#{e.role}"}>
              <animateMotion
                dur={"#{2.5 + rem(e.idx, 3)}s"}
                repeatCount="indefinite"
                path={"M#{e.fx},#{e.fy} L#{e.tx},#{e.ty}"}
                begin={"#{rem(e.idx * 700, 2500) / 1000}s"}
              />
            </circle>
          <% end %>
        <% end %>

        <!-- Live burst particles on recent messages -->
        <%= for p <- @recent do %>
          <circle r="3.5" class={"igraph-particle igraph-burst igraph-particle-#{p.role}"}>
            <animateMotion
              dur="0.7s"
              repeatCount="1"
              fill="freeze"
              path={"M#{p.fx},#{p.fy} L#{p.tx},#{p.ty}"}
            />
            <animate attributeName="opacity" values="1;0.9;0" dur="0.7s" fill="freeze" />
            <animate attributeName="r" values="3.5;5;2" dur="0.7s" fill="freeze" />
          </circle>
        <% end %>

        <!-- Agent nodes -->
        <%= for {_id, agent, x, y} <- @positions do %>
          <% slug = role_slug(agent[:agent_name]) %>
          <% busy = agent[:status] == :busy %>
          <!-- Pulse ring for busy agents -->
          <%= if busy do %>
            <circle cx={x} cy={y} r="20" class={"igraph-pulse-ring igraph-ring-#{slug}"} />
          <% end %>
          <!-- Outer glow ring -->
          <circle cx={x} cy={y} r="18" class={"igraph-node-glow igraph-node-#{slug}"} opacity="0.15" />
          <circle cx={x} cy={y} r="16" class={"igraph-node igraph-node-#{slug}"} />
          <text x={x} y={y} class="igraph-label"><%= avatar(agent[:agent_name]) %></text>
          <text x={x} y={Float.round(y + 26, 1)} class="igraph-name"><%= format_name(agent[:agent_name]) %></text>
        <% end %>
      </svg>
    </div>
    """
  end

  # --- Agent pill (sidebar) ---

  attr :agent, :map, required: true

  def agent_pill(assigns) do
    ~H"""
    <div class={"obs-agent-pill #{if @agent.status == :busy, do: "busy"} #{if !@agent.alive, do: "dead"}"}>
      <span class={"disc-avatar disc-avatar-#{role_slug(@agent.agent_name)} disc-avatar-sm"}><%= avatar(@agent.agent_name) %></span>
      <div class="obs-agent-pill-info">
        <span class="obs-agent-pill-name"><%= format_name(@agent.agent_name) %></span>
        <span class="obs-agent-pill-meta">
          <%= if @agent.current_tool, do: @agent.current_tool, else: @agent.status %>
          · step <%= @agent.current_step || 0 %>
        </span>
      </div>
      <span class={"obs-status-dot #{if @agent.status == :busy, do: "busy"}"}></span>
    </div>
    """
  end

  # --- Score table (sidebar) ---

  attr :scores, :map, required: true

  def score_table(assigns) do
    ~H"""
    <table class="obs-score-tbl">
      <thead>
        <tr><th>Candidate</th><th>T</th><th>C</th><th>$</th><th>Avg</th></tr>
      </thead>
      <tbody>
        <tr :for={{_id, s} <- sorted_scores(@scores)}>
          <td class="obs-score-name"><%= s.name %></td>
          <td class={score_cls(s.technical)}><%= s.technical || "—" %></td>
          <td class={score_cls(s.culture)}><%= s.culture || "—" %></td>
          <td class={score_cls(s.compensation)}><%= s.compensation || "—" %></td>
          <td class="obs-score-avg"><%= if s.avg, do: Float.round(s.avg, 1), else: "—" %></td>
        </tr>
      </tbody>
    </table>
    """
  end

  # --- Token summary (sidebar) ---

  attr :agents, :map, required: true

  def token_summary(assigns) do
    total_in = assigns.agents |> Map.values() |> Enum.map(& &1[:token_usage][:input] || 0) |> Enum.sum()
    total_out = assigns.agents |> Map.values() |> Enum.map(& &1[:token_usage][:output] || 0) |> Enum.sum()
    assigns = assign(assigns, :total_in, total_in) |> assign(:total_out, total_out)

    ~H"""
    <div class="obs-token-summary">
      <div class="obs-token-row">
        <span class="obs-token-label">Input</span>
        <span class="obs-token-value"><%= format_tokens(@total_in) %></span>
      </div>
      <div class="obs-token-row">
        <span class="obs-token-label">Output</span>
        <span class="obs-token-value"><%= format_tokens(@total_out) %></span>
      </div>
      <div class="obs-token-row obs-token-total">
        <span class="obs-token-label">Total</span>
        <span class="obs-token-value"><%= format_tokens(@total_in + @total_out) %></span>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  # Role colors: each role gets a consistent letter + color via CSS
  @role_avatars %{
    default: "C",
    primary: "C",
    technical_evaluator: "T",
    culture_evaluator: "U",
    compensation_evaluator: "$",
    coder: "⌥",
    researcher: "R"
  }

  defp avatar(name) when is_atom(name), do: Map.get(@role_avatars, name, String.first(Atom.to_string(name)) |> String.upcase())
  defp avatar(name) when is_binary(name) do
    cond do
      String.contains?(name, "technical") -> "T"
      String.contains?(name, "culture") -> "U"
      String.contains?(name, "compensation") -> "$"
      true -> String.first(name) |> String.upcase()
    end
  end
  defp avatar(_), do: "?"

  defp role_slug(name) when is_atom(name) do
    name |> Atom.to_string() |> String.replace("_", "-")
  end
  defp role_slug(name) when is_binary(name) do
    name |> String.replace("_", "-")
  end
  defp role_slug(_), do: "unknown"

  defp format_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.replace("_evaluator", "")
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
  defp format_name(name) when is_binary(name) do
    if String.contains?(name, "_evaluator") do
      name |> String.replace("_evaluator", "") |> String.capitalize()
    else
      if String.length(name) > 12, do: "..." <> String.slice(name, -8, 8), else: name
    end
  end
  defp format_name(name), do: to_string(name)

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max) <> "..."
  end
  defp truncate(text, _max), do: text

  defp sorted_scores(scores) do
    Enum.sort_by(scores, fn {_id, s} -> -(s.avg || 0) end)
  end

  defp score_cls(nil), do: "sc-pending"
  defp score_cls(n) when n >= 80, do: "sc-high"
  defp score_cls(n) when n >= 60, do: "sc-mid"
  defp score_cls(_), do: "sc-low"

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"
end
