defmodule RhoWeb.DataTable.Events.ArtifactActions do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias RhoWeb.DataTable.Artifacts
  alias RhoWeb.DataTable.Export

  def handle_event("open_save_dialog", _params, socket) do
    name = Artifacts.library_name_from_table(socket.assigns[:active_table])
    {:noreply, assign(socket, action_dialog: {:save, name})}
  end

  def handle_event("open_publish_dialog", _params, socket) do
    name = Artifacts.library_name_from_table(socket.assigns[:active_table])
    {:noreply, assign(socket, action_dialog: {:publish, name})}
  end

  def handle_event("open_suggest_dialog", _params, socket) do
    {:noreply, assign(socket, action_dialog: {:suggest, 5})}
  end

  def handle_event("close_dialog", _params, socket) do
    {:noreply, assign(socket, :action_dialog, nil)}
  end

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, :flash_message, nil)}
  end

  def handle_event("confirm_save", %{"name" => name}, socket) do
    active_table = socket.assigns[:active_table] || "main"
    send(self(), {:data_table_save, active_table, String.trim(name)})
    {:noreply, socket |> assign(:action_dialog, nil) |> assign(:flash_message, "Saving...")}
  end

  def handle_event("confirm_publish", %{"name" => name, "version_tag" => version_tag}, socket) do
    active_table = socket.assigns[:active_table] || "main"

    tag =
      case String.trim(version_tag) do
        "" -> nil
        t -> t
      end

    send(self(), {:data_table_publish, active_table, String.trim(name), tag})
    {:noreply, socket |> assign(:action_dialog, nil) |> assign(:flash_message, "Publishing...")}
  end

  def handle_event("confirm_suggest", %{"n" => n_str}, socket) do
    active_table = socket.assigns[:active_table] || "main"
    session_id = socket.assigns[:session_id]
    n = clamp_suggest_n(n_str)

    send(self(), {:suggest_skills, n, active_table, session_id})

    {:noreply,
     socket
     |> assign(:action_dialog, nil)
     |> assign(:flash_message, "Suggesting #{n} skills...")}
  end

  def handle_event("fork_library", _params, socket) do
    active_table = socket.assigns[:active_table] || "main"
    send(self(), {:data_table_fork, active_table})
    {:noreply, assign(socket, :flash_message, "Forking...")}
  end

  def handle_event("toggle_export_menu", _params, socket) do
    {:noreply, assign(socket, :export_menu_open, !socket.assigns.export_menu_open)}
  end

  def handle_event("close_export_menu", _params, socket) do
    {:noreply, assign(socket, :export_menu_open, false)}
  end

  def handle_event("export_csv", _params, socket) do
    rows = socket.assigns.rows
    schema = socket.assigns.schema
    active_table = socket.assigns[:active_table] || "main"

    csv = Export.build_csv(rows, schema)
    filename = String.replace(active_table, ~r/[^a-zA-Z0-9_-]/, "_") <> ".csv"

    socket =
      socket
      |> assign(:export_menu_open, false)
      |> push_event("csv-download", %{csv: csv, filename: filename})

    {:noreply, socket}
  end

  def handle_event("export_xlsx", _params, socket) do
    rows = socket.assigns.rows
    schema = socket.assigns.schema
    active_table = socket.assigns[:active_table] || "main"

    xlsx_binary = Export.build_xlsx(rows, schema)
    b64 = Base.encode64(xlsx_binary)
    filename = String.replace(active_table, ~r/[^a-zA-Z0-9_-]/, "_") <> ".xlsx"

    socket =
      socket
      |> assign(:export_menu_open, false)
      |> push_event("xlsx-download", %{data: b64, filename: filename})

    {:noreply, socket}
  end

  defp clamp_suggest_n(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> clamp_suggest_n(n)
      :error -> 5
    end
  end

  defp clamp_suggest_n(n) when is_integer(n), do: n |> max(1) |> min(10)
  defp clamp_suggest_n(_), do: 5
end
