defmodule RhoWeb.AppLive.LibraryEvents do
  @moduledoc false

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, assign: 3]
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  def handle_event("set_default_version", %{"id" => id}, socket) do
    org = socket.assigns.current_organization

    case RhoFrameworks.Library.set_default_version(org.id, id) do
      {:ok, lib} ->
        libraries = RhoFrameworks.Library.list_libraries(org.id)

        {:noreply,
         socket
         |> put_flash(:info, "Set v#{lib.version} as default for \"#{lib.name}\"")
         |> assign(libraries: libraries, library_groups: group_libraries(libraries))}

      {:error, :not_published, msg} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to set default version")}
    end
  end

  def handle_event("delete_library", %{"id" => id}, socket) do
    org = socket.assigns.current_organization
    RhoFrameworks.Library.delete_library(org.id, id)
    libraries = RhoFrameworks.Library.list_libraries(org.id)
    {:noreply, assign(socket, libraries: libraries, library_groups: group_libraries(libraries))}
  end

  def handle_event("set_default_version_from_show", %{"id" => id}, socket) do
    org = socket.assigns.current_organization

    case RhoFrameworks.Library.set_default_version(org.id, id) do
      {:ok, lib} ->
        {:noreply,
         socket
         |> put_flash(:info, "Set v#{lib.version} as default for \"#{lib.name}\"")
         |> assign(:library, lib)}

      {:error, :not_published, msg} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to set default version")}
    end
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    status = if status == "", do: nil, else: status
    library_id = socket.assigns.library.id
    opts = if status, do: [status: status], else: []
    index = RhoFrameworks.Library.list_skill_index(library_id, opts)
    grouped_index = RhoWeb.AppLive.group_skill_index(index)
    total = Enum.reduce(index, 0, fn row, acc -> acc + row.count end)

    socket =
      socket
      |> assign(
        skill_index: index,
        grouped_index: grouped_index,
        total_skill_count: total,
        cluster_skills: %{},
        open_clusters: MapSet.new(),
        open_categories: MapSet.new(),
        status_filter: status
      )
      |> RhoWeb.AppLive.refresh_skill_search()

    {:noreply, socket}
  end

  def handle_event("open_fork_modal", _params, socket) do
    default_name = "#{socket.assigns.library.name} (Custom)"
    {:noreply, assign(socket, show_fork_modal: true, fork_name: default_name)}
  end

  def handle_event("close_fork_modal", _params, socket) do
    {:noreply, assign(socket, show_fork_modal: false)}
  end

  def handle_event("update_fork_name", %{"fork_name" => name}, socket) do
    {:noreply, assign(socket, fork_name: name)}
  end

  def handle_event("submit_fork", %{"fork_name" => name}, socket) do
    org = socket.assigns.current_organization
    lib = socket.assigns.library

    try do
      case RhoFrameworks.Library.fork_library(org.id, lib.id, String.trim(name)) do
        {:ok, %{library: forked}} ->
          {:noreply,
           socket
           |> assign(:show_fork_modal, false)
           |> put_flash(:info, "Forked \"#{lib.name}\" → \"#{forked.name}\"")
           |> push_patch(to: ~p"/orgs/#{org.slug}/libraries/#{forked.id}")}

        {:error, _step, reason, _changes} ->
          {:noreply, put_flash(socket, :error, "Fork failed: #{inspect(reason)}")}
      end
    rescue
      Ecto.NoResultsError ->
        {:noreply, put_flash(socket, :error, "Cannot fork: library not found or not accessible.")}
    end
  end

  def handle_event("fork_and_edit", %{"id" => source_id}, socket) do
    org = socket.assigns.current_organization

    try do
      source = RhoFrameworks.Library.get_library!(org.id, source_id)
      new_name = "#{source.name} (copy)"

      case RhoFrameworks.Library.fork_library(org.id, source_id, new_name) do
        {:ok, %{library: forked}} ->
          {:noreply,
           socket
           |> put_flash(:info, "Forked \"#{source.name}\" → editing copy")
           |> push_navigate(
             to: ~p"/orgs/#{org.slug}/flows/edit-framework?library_id=#{forked.id}"
           )}

        {:error, _step, reason, _changes} ->
          {:noreply, put_flash(socket, :error, "Fork failed: #{inspect(reason)}")}
      end
    rescue
      Ecto.NoResultsError ->
        {:noreply, put_flash(socket, :error, "Cannot fork: library not found.")}
    end
  end

  def handle_event("show_diff", _params, socket) do
    org = socket.assigns.current_organization
    lib = socket.assigns.library

    case RhoFrameworks.Library.diff_against_source(org.id, lib.id) do
      {:ok, diff} ->
        {:noreply, assign(socket, show_diff: true, diff_result: diff)}

      {:error, _code, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("hide_diff", _params, socket) do
    {:noreply, assign(socket, show_diff: false, diff_result: nil)}
  end

  # Private helpers

  defp group_libraries(libraries) do
    libraries
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, versions} ->
      sorted = Enum.sort_by(versions, & &1.updated_at, {:desc, DateTime})
      primary = hd(sorted)

      %{
        name: name,
        description: primary.description,
        type: primary.type,
        primary: primary,
        versions: sorted,
        version_count: length(sorted)
      }
    end)
    |> Enum.sort_by(& &1.primary.updated_at, {:desc, DateTime})
  end
end
