defmodule RhoWeb.AppLive.PageLoader do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3, assign_new: 3, to_form: 1, to_form: 2]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]
  require Logger
  alias RhoWeb.AppLive.PageSearchEvents

  def page_for_action(:new), do: :chat
  def page_for_action(:show), do: :chat
  def page_for_action(:chat_new), do: :chat
  def page_for_action(:chat_show), do: :chat
  def page_for_action(:libraries), do: :libraries
  def page_for_action(:library_show), do: :library_show
  def page_for_action(:roles), do: :roles
  def page_for_action(:role_show), do: :role_show
  def page_for_action(:settings), do: :settings
  def page_for_action(:members), do: :members
  def page_for_action(_), do: :chat

  def apply_page(socket, :libraries, _params) do
    if connected?(socket) do
      org = socket.assigns.current_organization
      libraries = RhoFrameworks.Library.list_libraries(org.id)

      socket
      |> assign(:libraries, libraries)
      |> assign(:library_groups, group_libraries(libraries))
      |> assign(:library_search_query, "")
      |> assign_new(:smart_entry_pending?, fn -> false end)
    else
      socket
      |> assign(:libraries, [])
      |> assign(:library_groups, [])
      |> assign(:library_search_query, "")
      |> assign_new(:smart_entry_pending?, fn -> false end)
    end
  end

  def apply_page(socket, :library_show, params) do
    id = params["id"]

    if connected?(socket) && id do
      org = socket.assigns.current_organization
      t0 = System.monotonic_time(:microsecond)
      lib = RhoFrameworks.Library.get_visible_library!(org.id, id)
      t_lib = System.monotonic_time(:microsecond)
      index = RhoFrameworks.Library.list_skill_index(id)
      t_index = System.monotonic_time(:microsecond)
      grouped_index = PageSearchEvents.group_skill_index(index)
      t_group = System.monotonic_time(:microsecond)
      research_notes = RhoFrameworks.Library.list_research_notes(id)
      t_notes = System.monotonic_time(:microsecond)
      total_skills = Enum.reduce(index, 0, fn row, acc -> acc + row.count end)

      Logger.info(
        "[library_show timing] lib=#{div(t_lib - t0, 1000)}ms " <>
          "index=#{div(t_index - t_lib, 1000)}ms (#{length(index)} cells, #{total_skills} skills) " <>
          "group=#{div(t_group - t_index, 1000)}ms " <>
          "notes=#{div(t_notes - t_group, 1000)}ms " <> "total=#{div(t_notes - t0, 1000)}ms"
      )

      cluster_skills =
        case params["skill"] do
          nil ->
            %{}

          skill_id ->
            case RhoFrameworks.Library.cluster_for_skill(id, skill_id) do
              nil ->
                %{}

              {raw_cat, raw_cluster} ->
                %{
                  {raw_cat, raw_cluster} =>
                    RhoFrameworks.Library.list_cluster_skills(id, raw_cat, raw_cluster)
                }
            end
        end

      open_clusters = cluster_skills |> Map.keys() |> MapSet.new()

      open_categories =
        for {raw_cat, _raw_cluster} <- Map.keys(cluster_skills), into: MapSet.new(), do: raw_cat

      socket
      |> assign(:library, lib)
      |> assign(:skill_index, index)
      |> assign(:grouped_index, grouped_index)
      |> assign(:total_skill_count, total_skills)
      |> assign(:cluster_skills, cluster_skills)
      |> assign(:open_clusters, open_clusters)
      |> assign(:open_categories, open_categories)
      |> assign(:skill_search_results, nil)
      |> assign(:research_notes, research_notes)
      |> assign(:highlight_skill, params["skill"])
      |> maybe_scroll_to_skill(params["skill"])
      |> assign_new(:status_filter, fn -> nil end)
      |> assign_new(:show_fork_modal, fn -> false end)
      |> assign_new(:fork_name, fn -> "" end)
      |> assign_new(:show_diff, fn -> false end)
      |> assign_new(:diff_result, fn -> nil end)
      |> assign_new(:skill_search_query, fn -> "" end)
      |> PageSearchEvents.refresh_skill_search()
    else
      socket
      |> assign(:library, nil)
      |> assign(:skill_index, [])
      |> assign(:grouped_index, [])
      |> assign(:total_skill_count, 0)
      |> assign(:cluster_skills, %{})
      |> assign(:open_clusters, MapSet.new())
      |> assign(:open_categories, MapSet.new())
      |> assign(:skill_search_results, nil)
      |> assign(:research_notes, [])
      |> assign(:highlight_skill, nil)
      |> assign_new(:status_filter, fn -> nil end)
      |> assign_new(:show_fork_modal, fn -> false end)
      |> assign_new(:fork_name, fn -> "" end)
      |> assign_new(:show_diff, fn -> false end)
      |> assign_new(:diff_result, fn -> nil end)
      |> assign_new(:skill_search_query, fn -> "" end)
    end
  end

  def apply_page(socket, :roles, _params) do
    if connected?(socket) do
      org = socket.assigns.current_organization
      profiles = RhoFrameworks.Roles.list_role_profiles(org.id, include_public: false)
      grouped = group_roles_by_family(profiles)

      assign(socket,
        profiles: profiles,
        role_grouped: grouped,
        role_search_query: "",
        role_search_results: nil,
        role_search_pending?: false
      )
    else
      assign(socket,
        profiles: [],
        role_grouped: [],
        role_search_query: "",
        role_search_results: nil,
        role_search_pending?: false
      )
    end
  end

  def apply_page(socket, :role_show, params) do
    id = params["id"]

    if connected?(socket) && id do
      org = socket.assigns.current_organization
      rp = RhoFrameworks.Roles.get_visible_role_profile_with_skills!(org.id, id)
      role_skills_grouped = group_role_skills(rp.role_skills)
      assign(socket, profile: rp, role_skills_grouped: role_skills_grouped)
    else
      assign(socket, profile: nil, role_skills_grouped: %{})
    end
  end

  def apply_page(socket, :settings, _params) do
    org = socket.assigns.current_organization
    user = socket.assigns.current_user
    membership = socket.assigns.current_membership
    changeset = RhoFrameworks.Accounts.change_organization(org)
    user_changeset = RhoFrameworks.Accounts.change_user_profile(user)

    socket
    |> assign(:org_changeset, to_form(changeset))
    |> assign(:user_changeset, to_form(user_changeset, as: "user"))
    |> assign(:is_owner, RhoFrameworks.Accounts.Authorization.can?(membership, :manage_org))
  end

  def apply_page(socket, :members, _params) do
    org = socket.assigns.current_organization
    membership = socket.assigns.current_membership
    members = RhoFrameworks.Accounts.list_members(org.id)
    can_manage = RhoFrameworks.Accounts.Authorization.can?(membership, :manage_members)
    is_owner = RhoFrameworks.Accounts.Authorization.can?(membership, :manage_org)

    socket
    |> assign(:members, members)
    |> assign(:can_manage, can_manage)
    |> assign(:is_owner, is_owner)
    |> assign_new(:invite_email, fn -> "" end)
    |> assign_new(:invite_role, fn -> "member" end)
    |> assign_new(:invite_error, fn -> nil end)
  end

  def apply_page(socket, :chat, params) do
    library_id = params["library_id"]

    socket =
      if connected?(socket) do
        org = socket.assigns.current_organization
        assign(socket, :workbench_home_libraries, RhoFrameworks.Library.list_libraries(org.id))
      else
        assign(socket, :workbench_home_libraries, [])
      end

    if connected?(socket) && library_id do
      RhoWeb.AppLive.DataTableEvents.load_library_into_data_table(socket, library_id)
    else
      socket
    end
  end

  def apply_page(socket, _page, _params) do
    socket
  end

  defp maybe_scroll_to_skill(socket, nil), do: socket

  defp maybe_scroll_to_skill(socket, skill_id) do
    push_event(socket, "scroll_to_skill", %{skill_id: skill_id})
  end

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

  defp group_roles_by_family(profiles) do
    profiles
    |> Enum.group_by(& &1.role_family)
    |> Enum.sort_by(fn {family, _} -> family || "" end)
  end

  defp group_role_skills(role_skills) do
    role_skills
    |> Enum.sort_by(fn rs -> {rs.skill.category, rs.skill.cluster, rs.skill.name} end)
    |> Enum.group_by(fn rs -> rs.skill.category || "Other" end)
    |> Enum.sort_by(fn {cat, _} -> cat end)
    |> Enum.map(fn {category, skills} ->
      clusters =
        skills
        |> Enum.group_by(fn rs -> rs.skill.cluster || "General" end)
        |> Enum.sort_by(fn {cluster, _} -> cluster end)

      {category, clusters}
    end)
  end
end
