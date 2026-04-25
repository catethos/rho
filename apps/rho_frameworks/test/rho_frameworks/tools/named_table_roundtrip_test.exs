defmodule RhoFrameworks.Tools.NamedTableRoundtripTest do
  @moduledoc """
  Integration tests exercising the named-table migration for the
  frameworks domain tools. These hit the real
  `Rho.Stdlib.DataTable.Server` — no mocks — to verify that:

    * `load_library` writes rows into the library named table
    * `manage_role(action: load)` writes rows into the `"role_profile"` table
    * `save_library` / `manage_role(action: save)` read from their named tables
    * two named tables can coexist for a single session
    * save tools return an actionable error when no DataTable server is
      running for the session.
  """

  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.Library, as: LibraryCtx
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Tools.LibraryTools
  alias RhoFrameworks.Tools.RoleTools

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "Named Table Test Org",
      slug: "named-table-test-#{System.unique_integer([:positive])}"
    })

    # Unique session id per test so DataTable servers do not collide.
    session_id = "sess-nt-#{System.unique_integer([:positive])}"

    on_exit(fn -> DataTable.stop(session_id) end)

    ctx = %Rho.Context{
      agent_name: :test,
      organization_id: org_id,
      session_id: session_id,
      agent_id: "agent-test",
      tape_module: Rho.Tape.Null
    }

    %{org_id: org_id, session_id: session_id, ctx: ctx}
  end

  # --- Helpers ------------------------------------------------------------

  defp tool(module, name) do
    module.__tools__()
    |> Enum.find(&(&1.tool.name == name))
    |> Map.fetch!(:execute)
  end

  defp seed_library_with_skill(org_id) do
    {:ok, lib} =
      LibraryCtx.create_library(org_id, %{
        name: "Engineering",
        description: "Engineering skills"
      })

    {:ok, _skill} =
      LibraryCtx.upsert_skill(lib.id, %{
        category: "Software Development",
        cluster: "Programming",
        name: "Elixir",
        description: "OTP/BEAM",
        status: "published",
        proficiency_levels: [
          %{"level" => 1, "level_name" => "Novice", "level_description" => "Knows basics"},
          %{"level" => 3, "level_name" => "Competent", "level_description" => "Builds features"}
        ]
      })

    lib
  end

  defp seed_role_profile(org_id) do
    lib = seed_library_with_skill(org_id)
    manage_role = tool(RoleTools, "manage_role")

    # Prime the "role_profile" table for the save tool to read from.
    :ok =
      DataTable.ensure_table(
        "seed-#{System.unique_integer([:positive])}",
        "role_profile",
        RhoFrameworks.DataTableSchemas.role_profile_schema()
      )

    {lib, manage_role}
  end

  # --- library round trip -------------------------------------------------

  describe "library load → save round trip" do
    test "load_library writes into the library table and save_library reads from it",
         %{org_id: org_id, session_id: session_id, ctx: ctx} do
      lib = seed_library_with_skill(org_id)
      load = tool(LibraryTools, "load_library")
      save = tool(LibraryTools, "save_library")

      assert %Rho.ToolResponse{effects: effects} =
               load.(%{library_name: lib.name}, ctx)

      table_name = LibraryTools.library_table_name(lib.name)

      assert Enum.any?(effects, fn
               %Rho.Effect.Table{table_name: ^table_name, schema_key: :skill_library} -> true
               _ -> false
             end)

      # EffectDispatcher runs in the web layer; simulate its "canonical
      # write" step so the rows actually land in the named table.
      %Rho.Effect.Table{rows: rows} =
        Enum.find(effects, &match?(%Rho.Effect.Table{}, &1))

      {:ok, _} = DataTable.replace_all(session_id, rows, table: table_name)

      # Round trip: save_library should read from the library table.
      assert %Rho.ToolResponse{text: text} =
               save.(%{action: "save", library_id: lib.id}, ctx)

      assert text =~ "Saved"
      assert text =~ "skill"

      # And the "main" table should be untouched.
      assert DataTable.get_rows(session_id, table: "main") == []
    end

    test "save_library errors when the library is not found", %{ctx: ctx} do
      lib_id = Ecto.UUID.generate()
      save = tool(LibraryTools, "save_library")

      # Library doesn't exist — save should refuse.
      assert {:error, message} = save.(%{action: "save", library_id: lib_id}, ctx)
      assert message =~ "not found"
    end

    test "save_library errors when the library table is empty",
         %{org_id: org_id, session_id: session_id, ctx: ctx} do
      lib = seed_library_with_skill(org_id)
      save = tool(LibraryTools, "save_library")
      table_name = LibraryTools.library_table_name(lib.name)

      # Table exists but carries no rows.
      :ok =
        DataTable.ensure_table(
          session_id,
          table_name,
          RhoFrameworks.DataTableSchemas.library_schema()
        )

      assert {:error, message} = save.(%{action: "save", library_id: lib.id}, ctx)
      assert message =~ "empty"
    end
  end

  # --- role profile round trip -------------------------------------------

  describe "role_profile load → save round trip" do
    test "manage_role load writes into the role_profile table and save reads from it",
         %{org_id: org_id, session_id: session_id, ctx: ctx} do
      {lib, manage_role} = seed_role_profile(org_id)

      # Seed an existing role profile by saving one synthetically.
      :ok =
        DataTable.ensure_table(
          session_id,
          "role_profile",
          RhoFrameworks.DataTableSchemas.role_profile_schema()
        )

      {:ok, _} =
        DataTable.replace_all(
          session_id,
          [
            %{
              category: "Software Development",
              cluster: "Programming",
              skill_name: "Elixir",
              required_level: 3,
              required: true
            }
          ],
          table: "role_profile"
        )

      {:ok, _} =
        manage_role.(
          %{
            action: "save",
            name: "Senior Backend Engineer",
            role_family: "Engineering",
            seniority_level: 3,
            resolve_library_id: lib.id
          },
          ctx
        )

      # Clear the table and then load it back from storage.
      {:ok, _} = DataTable.replace_all(session_id, [], table: "role_profile")

      assert %Rho.ToolResponse{effects: effects} =
               manage_role.(%{action: "load", name: "Senior Backend Engineer"}, ctx)

      assert Enum.any?(effects, fn
               %Rho.Effect.Table{table_name: "role_profile", schema_key: :role_profile} -> true
               _ -> false
             end)

      %Rho.Effect.Table{rows: loaded_rows} =
        Enum.find(effects, &match?(%Rho.Effect.Table{}, &1))

      assert Enum.any?(loaded_rows, fn row ->
               row[:skill_name] == "Elixir" and row[:required_level] == 3
             end)
    end

    test "manage_role save errors when the server is not running", %{ctx: ctx} do
      manage_role = tool(RoleTools, "manage_role")

      assert {:error, message} =
               manage_role.(
                 %{action: "save", name: "Any Role", resolve_library_id: Ecto.UUID.generate()},
                 ctx
               )

      assert message =~ "role_profile"
    end
  end

  # --- two tables open simultaneously ------------------------------------

  describe "coexisting library + role_profile tables" do
    test "load_library then manage_role load leaves both tables populated",
         %{org_id: org_id, session_id: session_id, ctx: ctx} do
      lib = seed_library_with_skill(org_id)
      lib_table = LibraryTools.library_table_name(lib.name)

      # --- library tab ---
      load_lib = tool(LibraryTools, "load_library")

      %Rho.ToolResponse{effects: lib_effects} =
        load_lib.(%{library_name: lib.name}, ctx)

      %Rho.Effect.Table{rows: lib_rows, table_name: ^lib_table} =
        Enum.find(lib_effects, &match?(%Rho.Effect.Table{}, &1))

      {:ok, _} = DataTable.replace_all(session_id, lib_rows, table: lib_table)

      # --- role_profile tab ---
      # Seed a role profile in the DB by writing rows and saving.
      :ok =
        DataTable.ensure_table(
          session_id,
          "role_profile",
          RhoFrameworks.DataTableSchemas.role_profile_schema()
        )

      {:ok, _} =
        DataTable.replace_all(
          session_id,
          [
            %{
              category: "Software Development",
              cluster: "Programming",
              skill_name: "Elixir",
              required_level: 2,
              required: true
            }
          ],
          table: "role_profile"
        )

      manage_role = tool(RoleTools, "manage_role")

      {:ok, _} =
        manage_role.(
          %{
            action: "save",
            name: "Mid Engineer",
            role_family: "Engineering",
            resolve_library_id: lib.id
          },
          ctx
        )

      # Both tables should now exist for this session.
      tables = DataTable.list_tables(session_id)
      names = Enum.map(tables, & &1.name) |> Enum.sort()
      assert lib_table in names
      assert "role_profile" in names
      assert "main" in names

      assert DataTable.get_rows(session_id, table: lib_table) != []
      assert DataTable.get_rows(session_id, table: "role_profile") != []
    end
  end

  # --- start_role_profile_draft -----------------------------------------

  describe "start_role_profile_draft" do
    test "creates an empty role_profile table so add_rows can target it",
         %{session_id: session_id, ctx: ctx} do
      manage_role = tool(RoleTools, "manage_role")

      assert %Rho.ToolResponse{effects: effects, text: text} =
               manage_role.(%{action: "start_draft", mode_label: "My Draft"}, ctx)

      assert text =~ "role_profile"

      assert Enum.any?(effects, fn
               %Rho.Effect.Table{table_name: "role_profile", rows: []} -> true
               _ -> false
             end)

      # The table now exists and is empty — subsequent add_rows with
      # table: "role_profile" must succeed without :not_found.
      assert {:ok, [row]} =
               DataTable.add_rows(
                 session_id,
                 [
                   %{
                     skill_name: "Elixir",
                     required_level: 3,
                     required: true
                   }
                 ],
                 table: "role_profile"
               )

      assert row.skill_name == "Elixir"
    end
  end

  # --- org_view -----------------------------------------------------

  describe "org_view" do
    test "returns empty summary when the org has no role profiles",
         %{ctx: ctx} do
      view = tool(RoleTools, "org_view")
      assert {:ok, text} = view.(%{}, ctx)
      assert text =~ "0 roles"
    end

    test "computes shared vs unique skills across multiple role profiles",
         %{org_id: org_id, session_id: session_id, ctx: ctx} do
      lib = seed_library_with_skill(org_id)

      :ok =
        DataTable.ensure_table(
          session_id,
          "role_profile",
          RhoFrameworks.DataTableSchemas.role_profile_schema()
        )

      manage_role = tool(RoleTools, "manage_role")

      # Role A: Elixir + Python
      {:ok, _} =
        DataTable.replace_all(
          session_id,
          [
            %{
              category: "Software Development",
              cluster: "Programming",
              skill_name: "Elixir",
              required_level: 3,
              required: true
            },
            %{
              category: "Software Development",
              cluster: "Programming",
              skill_name: "Python",
              required_level: 2,
              required: true
            }
          ],
          table: "role_profile"
        )

      {:ok, _} =
        manage_role.(
          %{
            action: "save",
            name: "Backend Engineer",
            role_family: "Engineering",
            resolve_library_id: lib.id
          },
          ctx
        )

      # Role B: Elixir + Go (Elixir shared; Python and Go unique)
      {:ok, _} =
        DataTable.replace_all(
          session_id,
          [
            %{
              category: "Software Development",
              cluster: "Programming",
              skill_name: "Elixir",
              required_level: 4,
              required: true
            },
            %{
              category: "Software Development",
              cluster: "Programming",
              skill_name: "Go",
              required_level: 3,
              required: true
            }
          ],
          table: "role_profile"
        )

      {:ok, _} =
        manage_role.(
          %{
            action: "save",
            name: "Platform Engineer",
            role_family: "Engineering",
            resolve_library_id: lib.id
          },
          ctx
        )

      view = tool(RoleTools, "org_view")
      assert {:ok, text} = view.(%{}, ctx)
      assert text =~ "2 roles"
      assert text =~ "Elixir"
      assert text =~ "Backend Engineer"
      assert text =~ "Platform Engineer"
      assert text =~ "Engineering"
    end
  end
end
