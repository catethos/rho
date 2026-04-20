defmodule RhoWeb.PrismLiveTest do
  @moduledoc """
  Tests for the Prism LiveViews: RoleProfileListLive, RoleProfileShowLive,
  SkillLibraryShowLive.

  Uses manual socket construction (same pattern as session/ tests) with
  real DB data from rho_frameworks.
  """
  use ExUnit.Case, async: false

  alias RhoFrameworks.{Repo, Library, Roles}
  alias RhoFrameworks.Accounts.Organization

  setup do
    org_id = Ecto.UUID.generate()
    slug = "test-org-#{System.unique_integer([:positive])}"

    Repo.insert!(%Organization{id: org_id, name: "Test Org", slug: slug})

    org = %{id: org_id, slug: slug, name: "Test Org"}

    %{org_id: org_id, org: org}
  end

  defp build_socket(assigns_override) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          flash: %{}
        },
        assigns_override
      )

    struct!(Phoenix.LiveView.Socket, assigns: assigns)
  end

  # ── SkillLibraryShowLive ──────────────────────────────────────────────

  describe "SkillLibraryShowLive" do
    test "mount loads library and skills", %{org_id: org_id, org: org} do
      {:ok, lib} = Library.create_library(org_id, %{name: "Test Lib"})

      {:ok, _skill} =
        Library.upsert_skill(lib.id, %{
          name: "SQL",
          category: "Data",
          cluster: "Wrangling",
          description: "Structured queries",
          status: "published"
        })

      socket =
        build_socket(%{current_organization: org})
        |> put_private_connected(true)

      {:ok, socket} = RhoWeb.SkillLibraryShowLive.mount(%{"id" => lib.id}, %{}, socket)

      assert socket.assigns.library.name == "Test Lib"
      assert length(socket.assigns.skills) == 1
      assert hd(socket.assigns.skills).name == "SQL"
      assert socket.assigns.active_page == :libraries
    end

    test "filter_status event filters skills", %{org_id: org_id, org: org} do
      {:ok, lib} = Library.create_library(org_id, %{name: "Filter Lib"})

      Library.upsert_skill(lib.id, %{
        name: "Published Skill",
        category: "A",
        status: "published"
      })

      Library.upsert_skill(lib.id, %{
        name: "Draft Skill",
        category: "A",
        status: "draft"
      })

      socket =
        build_socket(%{
          current_organization: org,
          library: Repo.get!(RhoFrameworks.Frameworks.Library, lib.id),
          skills: Library.browse_library(lib.id),
          grouped: %{},
          status_filter: nil,
          active_page: :libraries
        })

      {:noreply, socket} =
        RhoWeb.SkillLibraryShowLive.handle_event(
          "filter_status",
          %{"status" => "draft"},
          socket
        )

      assert socket.assigns.status_filter == "draft"
      assert length(socket.assigns.skills) == 1
      assert hd(socket.assigns.skills).name == "Draft Skill"
    end

    test "disconnected mount returns nil library", %{org: org} do
      socket = build_socket(%{current_organization: org})

      {:ok, socket} =
        RhoWeb.SkillLibraryShowLive.mount(%{"id" => Ecto.UUID.generate()}, %{}, socket)

      assert socket.assigns.library == nil
      assert socket.assigns.skills == []
    end
  end

  # ── RoleProfileListLive ──────────────────────────────────────────────

  describe "RoleProfileListLive" do
    test "mount with no profiles returns empty", %{org: org} do
      socket =
        build_socket(%{current_organization: org})
        |> put_private_connected(true)

      {:ok, socket} = RhoWeb.RoleProfileListLive.mount(%{}, %{}, socket)

      assert socket.assigns.profiles == []
      assert socket.assigns.grouped == []
      assert socket.assigns.active_page == :roles
    end

    test "mount loads and groups profiles by family", %{org_id: org_id, org: org} do
      # Create a library and skills first
      {:ok, lib} = Library.create_library(org_id, %{name: "Test Skills"})

      Library.upsert_skill(lib.id, %{
        name: "Elixir",
        category: "Tech",
        status: "draft"
      })

      rows = [
        %{skill_name: "Elixir", category: "Tech", cluster: "", required_level: 3, required: true}
      ]

      {:ok, _} =
        Roles.save_role_profile(
          org_id,
          %{name: "Senior Engineer", role_family: "Engineering", seniority_level: 3},
          rows,
          library_id: lib.id
        )

      {:ok, _} =
        Roles.save_role_profile(
          org_id,
          %{name: "Staff Engineer", role_family: "Engineering", seniority_level: 4},
          rows,
          library_id: lib.id
        )

      {:ok, _} =
        Roles.save_role_profile(
          org_id,
          %{name: "Product Manager", role_family: "Product", seniority_level: 3},
          rows,
          library_id: lib.id
        )

      socket =
        build_socket(%{current_organization: org})
        |> put_private_connected(true)

      {:ok, socket} = RhoWeb.RoleProfileListLive.mount(%{}, %{}, socket)

      assert length(socket.assigns.profiles) == 3
      families = Enum.map(socket.assigns.grouped, fn {family, _} -> family end)
      assert "Engineering" in families
      assert "Product" in families
    end

    test "delete event removes a role profile", %{org_id: org_id, org: org} do
      {:ok, lib} = Library.create_library(org_id, %{name: "Del Test"})
      Library.upsert_skill(lib.id, %{name: "Go", category: "Tech", status: "draft"})

      rows = [
        %{skill_name: "Go", category: "Tech", cluster: "", required_level: 2, required: true}
      ]

      {:ok, _} = Roles.save_role_profile(org_id, %{name: "Backend Dev"}, rows, library_id: lib.id)

      # Verify it exists
      assert length(Roles.list_role_profiles(org_id)) == 1

      socket =
        build_socket(%{
          current_organization: org,
          profiles: Roles.list_role_profiles(org_id),
          grouped: [],
          active_page: :roles
        })

      {:noreply, socket} =
        RhoWeb.RoleProfileListLive.handle_event("delete", %{"name" => "Backend Dev"}, socket)

      assert socket.assigns.profiles == []
    end
  end

  # ── RoleProfileShowLive ──────────────────────────────────────────────

  describe "RoleProfileShowLive" do
    test "mount loads profile with skills", %{org_id: org_id, org: org} do
      {:ok, lib} = Library.create_library(org_id, %{name: "Show Test"})

      Library.upsert_skill(lib.id, %{
        name: "Python",
        category: "Languages",
        cluster: "Backend",
        description: "Python lang",
        status: "draft"
      })

      Library.upsert_skill(lib.id, %{
        name: "SQL",
        category: "Data",
        cluster: "Storage",
        description: "SQL queries",
        status: "draft"
      })

      rows = [
        %{
          skill_name: "Python",
          category: "Languages",
          cluster: "Backend",
          required_level: 3,
          required: true
        },
        %{
          skill_name: "SQL",
          category: "Data",
          cluster: "Storage",
          required_level: 2,
          required: true
        }
      ]

      {:ok, _} =
        Roles.save_role_profile(
          org_id,
          %{
            name: "Data Engineer",
            role_family: "Engineering",
            seniority_level: 3,
            purpose: "Build data pipelines"
          },
          rows,
          library_id: lib.id
        )

      rp = Roles.get_role_profile_by_name(org_id, "Data Engineer")

      socket =
        build_socket(%{current_organization: org})
        |> put_private_connected(true)

      {:ok, socket} = RhoWeb.RoleProfileShowLive.mount(%{"id" => rp.id}, %{}, socket)

      assert socket.assigns.profile.name == "Data Engineer"
      assert socket.assigns.profile.purpose == "Build data pipelines"
      assert socket.assigns.role_skills != []
      assert socket.assigns.active_page == :roles
    end

    test "disconnected mount returns nil profile", %{org: org} do
      socket = build_socket(%{current_organization: org})

      {:ok, socket} =
        RhoWeb.RoleProfileShowLive.mount(%{"id" => Ecto.UUID.generate()}, %{}, socket)

      assert socket.assigns.profile == nil
      assert socket.assigns.role_skills == %{}
    end
  end

  # ── Web schema resolution via RhoWeb.DataTable.Schemas ────────────────

  describe "DataTable web schema resolution" do
    alias RhoWeb.DataTable.Schemas

    test "resolves :role_profile view_key" do
      assert Schemas.resolve(:role_profile) == Schemas.role_profile()
    end

    test "resolves string view_key" do
      assert Schemas.resolve("skill_library") == Schemas.skill_library()
    end

    test "falls back to generic schema for unknown key" do
      assert Schemas.resolve(nil, "main") == Schemas.generic()
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # Simulate connected?(socket) returning true by setting the transport_pid
  defp put_private_connected(socket, true) do
    %{socket | transport_pid: self()}
  end
end
