defmodule RhoWeb.SessionLive.DataTableHelpersTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias Rho.Stdlib.DataTable
  alias RhoWeb.SessionLive.DataTableHelpers
  alias RhoFrameworks.{Library, Repo, Roles}
  alias RhoFrameworks.Accounts.Organization

  setup do
    org_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    slug = "dt-helper-org-#{System.unique_integer([:positive])}"

    Repo.insert!(%Organization{id: org_id, name: "Data Table Helper Org", slug: slug})

    sid = "dt_helper_#{System.unique_integer([:positive])}"
    on_exit(fn -> DataTable.stop(sid) end)

    {:ok, lib} = Library.create_library(org_id, %{name: "Programming"})

    %{
      lib: lib,
      org: %{id: org_id, slug: slug, name: "Data Table Helper Org"},
      sid: sid,
      user: %{id: user_id}
    }
  end

  test "handle_save persists the role_profile table as a role", %{
    lib: lib,
    org: org,
    sid: sid,
    user: user
  } do
    :ok =
      DataTable.ensure_table(
        sid,
        "role_profile",
        RhoFrameworks.DataTableSchemas.role_profile_schema()
      )

    {:ok, _rows} =
      DataTable.add_rows(
        sid,
        [
          %{
            category: "Core",
            cluster: "Language",
            skill_name: "Bitwise Operations",
            skill_description: "Apply bitwise operators.",
            required_level: 3,
            required: true
          }
        ],
        table: "role_profile"
      )

    socket = build_socket(sid, org, user, %{role_name: "Programming Role", library_id: lib.id})

    _socket = DataTableHelpers.handle_save(socket, "role_profile", "Programming Role")

    assert_receive {:data_table_flash, "Saved role 'Programming Role' — 1 skill(s)."}

    rp = Roles.get_role_profile_by_name(org.id, "Programming Role")
    assert rp.name == "Programming Role"

    assert {:ok,
            %{rows: [%{skill_name: "Bitwise Operations", required_level: 3, required: true}]}} =
             Roles.load_role_profile(org.id, "Programming Role")
  end

  test "handle_save can rename the role profile draft", %{
    lib: lib,
    org: org,
    sid: sid,
    user: user
  } do
    create_role_profile_table(sid)

    socket = build_socket(sid, org, user, %{role_name: "Programming Role", library_id: lib.id})

    socket = DataTableHelpers.handle_save(socket, "role_profile", "Senior Programming Role")

    assert_receive {:data_table_flash, "Saved role 'Senior Programming Role' — 1 skill(s)."}
    assert Roles.get_role_profile_by_name(org.id, "Senior Programming Role")
    refute Roles.get_role_profile_by_name(org.id, "Programming Role")

    metadata = socket.assigns.ws_states.data_table.metadata
    assert metadata.role_name == "Senior Programming Role"
    assert metadata.title == "Senior Programming Role Requirements"
    assert metadata.persisted? == true
  end

  test "handle_save stores the role group and uses the saved id for later renames", %{
    lib: lib,
    org: org,
    sid: sid,
    user: user
  } do
    create_role_profile_table(sid)

    socket = build_socket(sid, org, user, %{role_name: "Programming Role", library_id: lib.id})

    socket =
      DataTableHelpers.handle_save(socket, "role_profile", %{
        name: "Programming Role",
        role_family: "Digital, Data and IT Operations"
      })

    assert_receive {:data_table_flash, "Saved role 'Programming Role' — 1 skill(s)."}

    first = Roles.get_role_profile_by_name(org.id, "Programming Role")
    assert first.role_family == "Digital, Data and IT Operations"
    assert socket.assigns.ws_states.data_table.metadata.role_profile_id == first.id
    assert socket.assigns.ws_states.data_table.metadata.role_family == first.role_family

    socket =
      DataTableHelpers.handle_save(socket, "role_profile", %{
        name: "Senior Programming Role",
        role_family: "Engineering"
      })

    assert_receive {:data_table_flash, "Saved role 'Senior Programming Role' — 1 skill(s)."}
    refute Roles.get_role_profile_by_name(org.id, "Programming Role")

    renamed = Roles.get_role_profile_by_name(org.id, "Senior Programming Role")
    assert renamed.id == first.id
    assert renamed.role_family == "Engineering"
    assert socket.assigns.ws_states.data_table.metadata.role_family == "Engineering"
    assert "Engineering" in socket.assigns.role_group_options
  end

  defp build_socket(sid, org, user, metadata) do
    %Socket{
      assigns: %{
        __changed__: %{},
        session_id: sid,
        current_organization: org,
        current_user: user,
        role_group_options: [],
        ws_states: %{
          data_table: %{
            metadata: metadata
          }
        }
      }
    }
  end

  defp create_role_profile_table(sid) do
    :ok =
      DataTable.ensure_table(
        sid,
        "role_profile",
        RhoFrameworks.DataTableSchemas.role_profile_schema()
      )

    {:ok, _rows} =
      DataTable.add_rows(
        sid,
        [
          %{
            category: "Core",
            cluster: "Language",
            skill_name: "Bitwise Operations",
            skill_description: "Apply bitwise operators.",
            required_level: 3,
            required: true
          }
        ],
        table: "role_profile"
      )

    :ok
  end
end
