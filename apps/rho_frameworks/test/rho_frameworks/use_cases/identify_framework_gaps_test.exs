defmodule RhoFrameworks.UseCases.IdentifyFrameworkGapsTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{DataTableSchemas, Repo, Scope, Workbench}
  alias RhoFrameworks.UseCases.IdentifyFrameworkGaps

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "Gaps Test Org",
      slug: "gaps-test-#{System.unique_integer([:positive])}"
    })

    session_id = "sess-gaps-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:rho_frameworks, :identify_gaps_fn)
      DataTable.stop(session_id)
    end)

    scope = %Scope{
      organization_id: org_id,
      session_id: session_id,
      user_id: "user-test",
      source: :flow,
      reason: "wizard:create-framework"
    }

    %{scope: scope, session_id: session_id}
  end

  defp put_seam(parent, gaps) do
    Application.put_env(:rho_frameworks, :identify_gaps_fn, fn input ->
      send(parent, {:identify_called, input})
      {:ok, %{gaps: gaps}}
    end)
  end

  defp seed_table(session_id, table, rows) do
    {:ok, _} = DataTable.ensure_started(session_id)
    :ok = DataTable.ensure_table(session_id, table, DataTableSchemas.library_schema())

    scope = %Scope{
      organization_id: "org",
      session_id: session_id,
      user_id: "user-test",
      source: :flow,
      reason: "test:seed"
    }

    {:ok, _} = Workbench.replace_rows(scope, rows, table: table)
    :ok
  end

  describe "describe/0" do
    test "advertises cheap LLM cost" do
      assert %{id: :identify_framework_gaps, cost_hint: :cheap} =
               IdentifyFrameworkGaps.describe()
    end
  end

  describe "run/2" do
    test "errors when library_id is missing", %{scope: scope} do
      assert {:error, :missing_library_id} =
               IdentifyFrameworkGaps.run(%{table_name: "t"}, scope)
    end

    test "errors when table_name is missing", %{scope: scope} do
      assert {:error, :missing_table_name} =
               IdentifyFrameworkGaps.run(%{library_id: "lib-1"}, scope)
    end

    test "passes existing skills + intake to the seam and normalizes gaps", %{
      scope: scope,
      session_id: session_id
    } do
      seed_table(session_id, "library:Loaded", [
        %{
          category: "Eng",
          cluster: "Backend",
          skill_name: "API Design",
          skill_description: "Designs APIs"
        },
        %{
          category: "Eng",
          cluster: "Backend",
          skill_name: "DB Modeling",
          skill_description: "Models data"
        }
      ])

      put_seam(self(), [
        %{skill_name: "Caching", category: "Eng", rationale: "PMs need read-heavy patterns."},
        %{skill_name: "Observability", category: "Eng", rationale: "Production rigour."}
      ])

      input = %{
        library_id: "lib-loaded",
        table_name: "library:Loaded",
        intake: %{
          name: "Backend PM Framework",
          description: "PMs working with backend",
          domain: "Software",
          target_roles: "Backend PM"
        }
      }

      assert {:ok, result} = IdentifyFrameworkGaps.run(input, scope)
      assert result.library_id == "lib-loaded"
      assert result.table_name == "library:Loaded"
      assert result.gap_count == 2
      assert [%{skill_name: "Caching", category: "Eng"} | _] = result.gaps

      assert_received {:identify_called, seam_input}
      assert seam_input.framework_name == "Backend PM Framework"
      assert seam_input.domain == "Software"
      assert seam_input.target_roles == "Backend PM"
      assert seam_input.existing_skills =~ "API Design"
      assert seam_input.existing_skills =~ "DB Modeling"
    end

    test "renders empty placeholder when the loaded framework has no rows", %{
      scope: scope,
      session_id: session_id
    } do
      seed_table(session_id, "library:Empty", [])
      put_seam(self(), [])

      assert {:ok, %{gap_count: 0, gaps: []}} =
               IdentifyFrameworkGaps.run(
                 %{library_id: "x", table_name: "library:Empty", intake: %{name: "X"}},
                 scope
               )

      assert_received {:identify_called, seam_input}
      assert seam_input.existing_skills =~ "(none"
    end

    test "propagates seam errors", %{scope: scope, session_id: session_id} do
      seed_table(session_id, "library:E", [])

      Application.put_env(:rho_frameworks, :identify_gaps_fn, fn _ ->
        {:error, :boom}
      end)

      assert {:error, :boom} =
               IdentifyFrameworkGaps.run(
                 %{library_id: "x", table_name: "library:E", intake: %{}},
                 scope
               )
    end
  end
end
