defmodule RhoWeb.DataTable.Events.ArtifactActions do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias RhoWeb.DataTable.Artifacts
  alias RhoWeb.DataTable.Export

  def handle_event("open_save_dialog", _params, socket) do
    artifact = Artifacts.active_artifact(socket.assigns[:workbench_context])

    dialog =
      if role_profile_view?(socket) do
        {:save_role, role_name_from_artifact(artifact), role_family_from_artifact(artifact)}
      else
        {:save, Artifacts.library_name_from_table(socket.assigns[:active_table])}
      end

    {:noreply, assign(socket, action_dialog: dialog)}
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

  def handle_event("noop", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, :flash_message, nil)}
  end

  def handle_event("confirm_save", %{"name" => name} = params, socket) do
    active_table = socket.assigns[:active_table] || "main"

    save_payload =
      if role_profile_view?(socket) do
        %{name: String.trim(name), role_family: blank_to_nil(params["role_family"])}
      else
        String.trim(name)
      end

    flash_message =
      if role_profile_view?(socket) do
        "Saving role and updating search index..."
      else
        "Saving..."
      end

    send(self(), {:data_table_save, active_table, save_payload})
    {:noreply, socket |> assign(:action_dialog, nil) |> assign(:flash_message, flash_message)}
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

  def handle_event("create_role_profile", _params, socket) do
    send(self(), {:create_role_profile_from_library, role_profile_source(socket)})
    {:noreply, assign(socket, :flash_message, "Creating role draft...")}
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

  defp role_profile_source(socket) do
    active_table = socket.assigns[:active_table] || "main"
    artifact = Artifacts.active_artifact(socket.assigns[:workbench_context])
    linked = (artifact && artifact.linked) || %{}
    library_name = linked[:library_name] || Artifacts.library_name_from_table(active_table)
    title = (artifact && artifact.title) || library_name || "Role"

    %{
      active_table: active_table,
      library_id: linked[:library_id],
      library_name: blank_to_nil(library_name),
      role_name: "#{base_role_name(title, library_name)} Role"
    }
  end

  defp base_role_name(title, library_name) do
    cond do
      is_binary(library_name) and library_name != "" ->
        library_name

      is_binary(title) ->
        String.replace_suffix(title, " Skill Framework", "")

      true ->
        "New"
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp role_profile_view?(socket) do
    artifact = Artifacts.active_artifact(socket.assigns[:workbench_context])

    socket.assigns[:view_key] in [:role_profile, "role_profile"] or
      socket.assigns[:active_table] == "role_profile" or
      (artifact && artifact.kind == :role_profile)
  end

  defp role_name_from_artifact(nil), do: "New Role"

  defp role_name_from_artifact(artifact) do
    artifact.linked[:role_name] ||
      artifact_role_name_from_title(artifact.title) ||
      "New Role"
  end

  defp role_family_from_artifact(nil), do: nil

  defp role_family_from_artifact(artifact) do
    artifact.linked[:role_family]
  end

  defp artifact_role_name_from_title(title) when is_binary(title) do
    title
    |> String.replace_suffix(" Role Requirements", "")
    |> String.replace_suffix(" Requirements", "")
  end

  defp artifact_role_name_from_title(_), do: nil
end
