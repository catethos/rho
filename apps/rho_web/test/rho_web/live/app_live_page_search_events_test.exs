defmodule RhoWeb.AppLivePageSearchEventsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.AppLive.PageSearchEvents

  defp socket(assigns) do
    base = %{__changed__: %{}}
    struct!(Phoenix.LiveView.Socket, assigns: Map.merge(base, assigns))
  end

  describe "library filtering" do
    test "matches group names and version names case-insensitively" do
      groups = [
        %{name: "SFIA", versions: [%{name: "SFIA v8"}]},
        %{name: "Data", versions: [%{name: "DAMA Body of Knowledge"}]}
      ]

      assert PageSearchEvents.filter_library_groups(groups, "sfia") == [hd(groups)]
      assert PageSearchEvents.filter_library_groups(groups, "body") == [List.last(groups)]
      assert PageSearchEvents.filter_library_groups(groups, "") == groups
      assert PageSearchEvents.filter_library_groups(groups, nil) == groups
    end
  end

  describe "skill grouping" do
    test "groups concrete skills by category and cluster" do
      skills = [
        %{category: "Data", cluster: nil, name: "SQL"},
        %{category: nil, cluster: "Runtime", name: "Elixir"}
      ]

      assert [
               {"Data", [{"General", [%{name: "SQL"} = _sql]}]},
               {"Other", [{"Runtime", [%{name: "Elixir"} = _elixir]}]}
             ] = PageSearchEvents.group_skills(skills)
    end

    test "groups skill index rows without losing raw category and cluster values" do
      index = [
        %{category: nil, cluster: nil, count: 2},
        %{category: "Tech", cluster: "Backend", count: 3}
      ]

      assert PageSearchEvents.group_skill_index(index) == [
               {"Other", [{"General", nil, nil, 2}]},
               {"Tech", [{"Backend", "Tech", "Backend", 3}]}
             ]
    end
  end

  describe "handlers" do
    test "search_libraries stores the query" do
      {:noreply, after_socket} =
        PageSearchEvents.handle_event("search_libraries", %{"q" => "sfia"}, socket(%{}))

      assert after_socket.assigns.library_search_query == "sfia"
    end

    test "toggle_category opens and closes blank category as nil" do
      socket = socket(%{open_categories: MapSet.new()})

      {:noreply, after_open} =
        PageSearchEvents.handle_event("toggle_category", %{"category" => ""}, socket)

      assert MapSet.member?(after_open.assigns.open_categories, nil)

      {:noreply, after_close} =
        PageSearchEvents.handle_event("toggle_category", %{"category" => ""}, after_open)

      refute MapSet.member?(after_close.assigns.open_categories, nil)
    end

    test "semantic search async result only applies to the current query" do
      socket =
        socket(%{
          role_search_query: "backend",
          role_search_results: [],
          role_search_pending?: true
        })

      {:noreply, stale_socket} =
        PageSearchEvents.handle_async(
          :semantic_search,
          {:ok, %{query: "frontend", results: [:ignored]}},
          socket
        )

      assert stale_socket.assigns.role_search_results == []
      assert stale_socket.assigns.role_search_pending?

      {:noreply, fresh_socket} =
        PageSearchEvents.handle_async(
          :semantic_search,
          {:ok, %{query: "backend", results: [:role]}},
          socket
        )

      assert fresh_socket.assigns.role_search_results == [:role]
      refute fresh_socket.assigns.role_search_pending?
    end

    test "refresh_skill_search clears results without a library or query" do
      assert PageSearchEvents.refresh_skill_search(
               socket(%{library: nil, skill_search_query: "sql"})
             ).assigns.skill_search_results == nil

      assert PageSearchEvents.refresh_skill_search(
               socket(%{library: %{id: "lib"}, skill_search_query: ""})
             ).assigns.skill_search_results == nil
    end
  end
end
