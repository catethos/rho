defmodule RhoWeb.AppLive.PageSearchEvents do
  @moduledoc """
  Page-scoped search and filtering handlers for `RhoWeb.AppLive`.

  These handlers belong to the library/role pages rather than the root
  LiveView shell: library list filtering, skill search, cluster expansion, and
  role-profile search async state.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [cancel_async: 2, start_async: 3]

  def handle_event("search_libraries", %{"q" => q}, socket) do
    {:noreply, assign(socket, :library_search_query, q)}
  end

  def handle_event("search_skills", %{"q" => q}, socket) do
    socket = socket |> assign(:skill_search_query, q) |> refresh_skill_search()
    {:noreply, socket}
  end

  def handle_event("toggle_category", %{"category" => cat}, socket) do
    raw_cat = blank_to_nil(cat)
    open = socket.assigns.open_categories

    open =
      if MapSet.member?(open, raw_cat) do
        MapSet.delete(open, raw_cat)
      else
        MapSet.put(open, raw_cat)
      end

    {:noreply, assign(socket, :open_categories, open)}
  end

  def handle_event("load_cluster", %{"category" => cat, "cluster" => cluster}, socket) do
    library_id = socket.assigns.library.id
    raw_cat = blank_to_nil(cat)
    raw_cluster = blank_to_nil(cluster)
    key = {raw_cat, raw_cluster}
    open = socket.assigns.open_clusters

    if MapSet.member?(open, key) do
      {:noreply, assign(socket, :open_clusters, MapSet.delete(open, key))}
    else
      cache = ensure_cluster_loaded(socket, key, library_id, raw_cat, raw_cluster)

      {:noreply,
       socket |> assign(:cluster_skills, cache) |> assign(:open_clusters, MapSet.put(open, key))}
    end
  end

  def handle_event("search_roles", %{"q" => q}, socket) do
    query = String.trim(q)
    org_id = socket.assigns.current_organization.id

    case query do
      "" ->
        {:noreply,
         socket
         |> cancel_async(:semantic_search)
         |> assign(:role_search_query, q)
         |> assign(:role_search_results, nil)
         |> assign(:role_search_pending?, false)}

      _ ->
        fast_results = RhoFrameworks.Roles.find_similar_roles_fast(org_id, query, limit: 50)

        socket =
          socket
          |> cancel_async(:semantic_search)
          |> assign(:role_search_query, q)
          |> assign(:role_search_results, fast_results)
          |> assign(:role_search_pending?, true)
          |> start_async(:semantic_search, fn ->
            results = RhoFrameworks.Roles.find_similar_roles_semantic(org_id, query, limit: 50)
            %{query: query, results: results}
          end)

        {:noreply, socket}
    end
  end

  def handle_async(:semantic_search, {:ok, %{query: q, results: results}}, socket) do
    if socket.assigns.role_search_query == q do
      {:noreply,
       socket |> assign(:role_search_results, results) |> assign(:role_search_pending?, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:semantic_search, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :role_search_pending?, false)}
  end

  def filter_library_groups(groups, query) when is_binary(query) do
    case String.trim(query) do
      "" ->
        groups

      needle ->
        needle = String.downcase(needle)

        Enum.filter(groups, fn g ->
          String.contains?(String.downcase(g.name), needle) or
            Enum.any?(g.versions, fn lib ->
              String.contains?(String.downcase(lib.name), needle)
            end)
        end)
    end
  end

  def filter_library_groups(groups, _) do
    groups
  end

  def group_skills(skills) do
    skills
    |> Enum.sort_by(fn s -> {s.category, s.cluster, s.name} end)
    |> Enum.group_by(fn s -> s.category || "Other" end)
    |> Enum.sort_by(fn {cat, _} -> cat end)
    |> Enum.map(fn {category, cat_skills} ->
      clusters =
        cat_skills
        |> Enum.group_by(fn s -> s.cluster || "General" end)
        |> Enum.sort_by(fn {cluster, _} -> cluster end)

      {category, clusters}
    end)
  end

  def group_skill_index(index) do
    index
    |> Enum.chunk_by(fn %{category: c} -> c end)
    |> Enum.map(fn rows ->
      raw_category = hd(rows).category

      clusters =
        Enum.map(rows, fn %{cluster: cl, count: n} -> {cl || "General", raw_category, cl, n} end)

      {raw_category || "Other", clusters}
    end)
  end

  def refresh_skill_search(socket) do
    library = socket.assigns[:library]
    query = String.trim(socket.assigns[:skill_search_query] || "")

    cond do
      is_nil(library) ->
        assign(socket, :skill_search_results, nil)

      query == "" ->
        assign(socket, :skill_search_results, nil)

      true ->
        opts =
          case socket.assigns[:status_filter] do
            nil -> []
            status -> [status: status]
          end

        results = RhoFrameworks.Library.search_in_library(library.id, query, opts)
        assign(socket, :skill_search_results, results)
    end
  end

  defp ensure_cluster_loaded(socket, key, library_id, raw_cat, raw_cluster) do
    case Map.fetch(socket.assigns.cluster_skills, key) do
      {:ok, _} ->
        socket.assigns.cluster_skills

      :error ->
        opts =
          case socket.assigns[:status_filter] do
            nil -> []
            status -> [status: status]
          end

        skills = RhoFrameworks.Library.list_cluster_skills(library_id, raw_cat, raw_cluster, opts)
        Map.put(socket.assigns.cluster_skills, key, skills)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
