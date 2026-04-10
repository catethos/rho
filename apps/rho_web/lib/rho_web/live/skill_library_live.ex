defmodule RhoWeb.SkillLibraryLive do
  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  import RhoWeb.CoreComponents

  alias RhoFrameworks.Library
  alias RhoWeb.Projections.DataTableProjection

  @impl true
  def mount(_params, _session, socket) do
    libraries =
      if connected?(socket) do
        org = socket.assigns.current_organization
        Library.list_libraries(org.id)
      else
        []
      end

    {:ok,
     socket
     |> assign(libraries: libraries, active_page: :libraries)
     |> assign(:chat_overlay_open, false)
     |> assign(:overlay_session_id, nil)
     |> assign(:bus_subs, [])
     |> assign(:dt_projection, nil)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    org = socket.assigns.current_organization
    Library.delete_library(org.id, id)
    libraries = Library.list_libraries(org.id)
    {:noreply, assign(socket, libraries: libraries)}
  end

  def handle_event("open_chat_overlay", _params, socket) do
    {:noreply, assign(socket, :chat_overlay_open, true)}
  end

  def handle_event("close_chat_overlay", _params, socket) do
    {:noreply, close_overlay(socket)}
  end

  @impl true
  def handle_info({:chat_overlay_started, session_id}, socket) do
    # Subscribe to signals for the overlay's session
    {:ok, sub1} = Rho.Comms.subscribe("rho.session.#{session_id}.events.*")
    {:ok, sub2} = Rho.Comms.subscribe("rho.agent.*")

    # Register this LiveView PID so DataTable tools can read rows synchronously
    Rho.Stdlib.Plugins.DataTable.register(session_id, self())

    {:noreply,
     socket
     |> assign(:overlay_session_id, session_id)
     |> assign(:bus_subs, [sub1, sub2])
     |> assign(:dt_projection, DataTableProjection.init())}
  end

  def handle_info({:chat_overlay_closed, _session_id}, socket) do
    {:noreply, close_overlay(socket)}
  end

  def handle_info({:signal, %Jido.Signal{type: type} = signal} = signal_msg, socket) do
    send_update(RhoWeb.ChatOverlayComponent, id: "chat-overlay", signal: signal_msg)

    socket =
      if socket.assigns[:dt_projection] && DataTableProjection.handles?(type) do
        assign(
          socket,
          :dt_projection,
          DataTableProjection.reduce(socket.assigns.dt_projection, signal)
        )
      else
        socket
      end

    {:noreply, socket}
  end

  # Synchronous read request from Rho.Stdlib.Plugins.DataTable.read_rows/1
  def handle_info({:data_table_get_table, {caller_pid, ref}, filter}, socket) do
    rows =
      case socket.assigns[:dt_projection] do
        %{rows_map: rows_map} ->
          rows_map |> Map.values() |> DataTableProjection.filter_rows(filter)

        _ ->
          []
      end

    send(caller_pid, {ref, {:ok, rows}})
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    for sub <- socket.assigns[:bus_subs] || [] do
      Rho.Comms.unsubscribe(sub)
    end

    if sid = socket.assigns[:overlay_session_id] do
      Rho.Stdlib.Plugins.DataTable.unregister(sid)
    end
  end

  defp close_overlay(socket) do
    for sub <- socket.assigns[:bus_subs] || [] do
      Rho.Comms.unsubscribe(sub)
    end

    if sid = socket.assigns[:overlay_session_id] do
      Rho.Stdlib.Plugins.DataTable.unregister(sid)
    end

    # Refresh libraries in case a new one was created via the chat
    org = socket.assigns.current_organization
    libraries = Library.list_libraries(org.id)

    socket
    |> assign(:chat_overlay_open, false)
    |> assign(:overlay_session_id, nil)
    |> assign(:bus_subs, [])
    |> assign(:dt_projection, nil)
    |> assign(:libraries, libraries)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell>
      <.page_header title="Skill Libraries" subtitle="Browse and manage skill catalogs">
        <:actions>
          <button phx-click="open_chat_overlay" class="btn-primary">
            + New Library
          </button>
        </:actions>
      </.page_header>

      <.empty_state :if={@libraries == []}>
        No libraries yet. Create one in the chat editor or load a standard template.
      </.empty_state>

      <div :if={@libraries != []} class="framework-grid">
        <.card :for={lib <- @libraries}>
          <div class="framework-card-top">
            <.link
              navigate={~p"/orgs/#{@current_organization.slug}/libraries/#{lib.id}"}
              class="framework-card-name"
            >
              <%= lib.name %>
            </.link>
            <span :if={lib.immutable} class="badge-immutable">Standard</span>
            <span class="badge-muted"><%= lib.skill_count %> skills</span>
          </div>
          <p :if={lib.description} class="framework-card-desc"><%= lib.description %></p>
          <div class="framework-card-footer">
            <span class="framework-card-date">
              Updated <%= Calendar.strftime(lib.updated_at, "%b %d, %Y") %>
            </span>
            <button
              phx-click="delete"
              phx-value-id={lib.id}
              data-confirm={"Delete library '#{lib.name}' and all its skills?"}
              class="btn-danger-sm"
            >
              Delete
            </button>
          </div>
        </.card>
      </div>

      <.live_component
        module={RhoWeb.ChatOverlayComponent}
        id="chat-overlay"
        open={@chat_overlay_open}
        agent_name={:spreadsheet}
        intent="I'd like to create a new skill library for this organization. Please help me define it."
        current_user={@current_user}
        current_organization={@current_organization}
      />
    </.page_shell>
    """
  end
end
