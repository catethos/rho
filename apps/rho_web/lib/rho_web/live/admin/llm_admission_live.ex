defmodule RhoWeb.Admin.LLMAdmissionLive do
  @moduledoc """
  Operator dashboard for the LLM admission controller. Shows real-time
  slot utilization, queue depth, and a rolling event feed.

  Mounted at `/admin/llm` (behind `:require_authenticated_user`). For
  production, gate this with an admin role plug before exposing.
  """

  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  alias Rho.LLM.Admission

  # Rolling window of recent telemetry events shown in the feed.
  @max_events 50
  # Auto-refresh stats this often (ms). Cheap: stats/0 is one GenServer.call.
  @refresh_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      handler_id = {:admin_llm_admission, self()}

      :telemetry.attach_many(
        handler_id,
        [
          [:rho, :llm, :admission, :acquire],
          [:rho, :llm, :admission, :release],
          [:rho, :llm, :admission, :queued],
          [:rho, :llm, :admission, :timeout]
        ],
        &__MODULE__.forward_event/4,
        self()
      )

      # Detach handler when the LV process dies.
      Process.put(:admission_handler_id, handler_id)

      Process.send_after(self(), :tick, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:stats, safe_stats())
     |> assign(:events, [])
     |> assign(:refresh_ms, @refresh_ms)
     |> assign(:active_page, :admin_llm)}
  end

  @impl true
  def terminate(_reason, _socket) do
    case Process.get(:admission_handler_id) do
      nil -> :ok
      id -> :telemetry.detach(id)
    end
  end

  # Telemetry handler — runs in the emitting process, so forward to LV
  # via send/2 rather than doing any work inline.
  def forward_event(event, measurements, metadata, lv_pid) do
    send(
      lv_pid,
      {:admission_event, event, measurements, metadata, System.system_time(:millisecond)}
    )
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, assign(socket, :stats, safe_stats())}
  end

  def handle_info({:admission_event, event, measurements, metadata, ts}, socket) do
    entry = %{
      event: List.last(event),
      ts: ts,
      measurements: measurements,
      metadata: metadata
    }

    events = [entry | socket.assigns.events] |> Enum.take(@max_events)
    {:noreply, assign(socket, :events, events)}
  end

  defp safe_stats do
    try do
      Admission.stats()
    catch
      :exit, _ -> %{in_flight: 0, capacity: 0, waiting: 0}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page-shell">
      <header class="page-header">
        <div class="page-header-text">
          <h1 class="page-title">LLM Admission Controller</h1>
          <p class="page-subtitle">Real-time slot utilization, queue depth, and a rolling telemetry feed.</p>
        </div>
      </header>

      <section class="admin-section">
        <div class="rho-card">
          <h2 class="admin-section-title">Current state</h2>

          <dl class="admin-stat-grid">
            <div>
              <dt class="admin-stat-label">In-flight</dt>
              <dd class="admin-stat-value">{@stats.in_flight}</dd>
            </div>
            <div>
              <dt class="admin-stat-label">Capacity</dt>
              <dd class="admin-stat-value">{@stats.capacity}</dd>
            </div>
            <div>
              <dt class="admin-stat-label">Waiting</dt>
              <dd class={"admin-stat-value " <> if(@stats.waiting > 0, do: "warn", else: "")}>{@stats.waiting}</dd>
            </div>
          </dl>

          <div class="admin-util">
            <div class="admin-util-header">
              <span>Utilization</span>
              <span>{utilization_pct(@stats)}%</span>
            </div>
            <div class="admin-util-bar">
              <div
                class={"admin-util-fill " <> utilization_class(@stats)}
                style={"width: #{utilization_pct(@stats)}%"}
              >
              </div>
            </div>
          </div>
        </div>
      </section>

      <section class="admin-section">
        <div class="rho-card">
          <h2 class="admin-section-title">Recent events ({length(@events)})</h2>

          <%= if Enum.empty?(@events) do %>
            <div class="empty-state">
              No events yet — events will appear here as LLM streams start and finish.
            </div>
          <% else %>
            <table class="rho-table">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Event</th>
                  <th>Measurements</th>
                  <th>Meta</th>
                </tr>
              </thead>
              <tbody>
                <%= for e <- @events do %>
                  <tr>
                    <td><span class="admin-event-time">{format_ts(e.ts)}</span></td>
                    <td><span class={"admin-event-name " <> event_class(e.event)}>{e.event}</span></td>
                    <td><span class="admin-event-measurements">{format_measurements(e.event, e.measurements)}</span></td>
                    <td><span class="admin-event-meta">{format_metadata(e.metadata)}</span></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </div>
      </section>

      <p class="admin-footnote">
        Refreshes every {@refresh_ms}ms. Events streamed live via :telemetry.
      </p>
    </div>
    """
  end

  defp utilization_pct(%{in_flight: in_flight, capacity: capacity}) when capacity > 0 do
    round(in_flight / capacity * 100)
  end

  defp utilization_pct(_), do: 0

  defp utilization_class(%{in_flight: in_flight, capacity: capacity, waiting: waiting}) do
    ratio = if capacity > 0, do: in_flight / capacity, else: 0

    cond do
      waiting > 0 -> "danger"
      ratio > 0.8 -> "danger"
      ratio > 0.5 -> "warn"
      true -> ""
    end
  end

  defp event_class(:acquire), do: "acquire"
  defp event_class(:release), do: "release"
  defp event_class(:queued), do: "queued"
  defp event_class(:timeout), do: "timeout"
  defp event_class(_), do: "release"

  defp format_ts(ms) do
    {:ok, dt} = DateTime.from_unix(ms, :millisecond)
    dt |> DateTime.to_time() |> Time.to_string() |> String.slice(0, 12)
  end

  defp format_measurements(:acquire, %{wait_ms: w, in_flight: f, capacity: c}),
    do: "wait=#{w}ms in_flight=#{f}/#{c}"

  defp format_measurements(:release, %{hold_ms: h, in_flight: f, capacity: c}),
    do: "hold=#{h}ms in_flight=#{f}/#{c}"

  defp format_measurements(:queued, %{queue_depth: q, in_flight: f, capacity: c}),
    do: "queue=#{q} in_flight=#{f}/#{c}"

  defp format_measurements(:timeout, %{wait_ms: w, in_flight: f, capacity: c, waiting: wg}),
    do: "waited=#{w}ms in_flight=#{f}/#{c} still_waiting=#{wg}"

  defp format_measurements(_, m), do: inspect(m, limit: 3)

  defp format_metadata(%{pid: pid, source: src}), do: "pid=#{inspect(pid)} src=#{src}"
  defp format_metadata(%{pid: pid, reason: r}), do: "pid=#{inspect(pid)} reason=#{r}"
  defp format_metadata(%{pid: pid}), do: "pid=#{inspect(pid)}"
  defp format_metadata(m), do: inspect(m, limit: 3)
end
