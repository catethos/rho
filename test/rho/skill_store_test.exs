defmodule Rho.SkillStoreTest do
  # NOTE: async: false because ecto_sqlite3 does not support SQL.Sandbox
  # and tests share a single SQLite DB file
  use ExUnit.Case, async: false

  alias Rho.SkillStore

  setup do
    # Use on_exit to guarantee cleanup even if test crashes
    on_exit(fn ->
      Rho.SkillStore.Repo.delete_all(Rho.SkillStore.FrameworkRow)
      Rho.SkillStore.Repo.delete_all(Rho.SkillStore.Framework)
      Rho.SkillStore.Repo.delete_all(Rho.SkillStore.Company)
    end)

    # Also clean before to ensure fresh state
    Rho.SkillStore.Repo.delete_all(Rho.SkillStore.FrameworkRow)
    Rho.SkillStore.Repo.delete_all(Rho.SkillStore.Framework)
    Rho.SkillStore.Repo.delete_all(Rho.SkillStore.Company)
    :ok
  end

  # Helper to build a complete row fixture
  defp full_row(overrides \\ %{}) do
    Map.merge(
      %{
        role: "",
        category: "Technical",
        cluster: "Programming",
        skill_name: "Test Skill",
        skill_description: "A test skill",
        level: 1,
        level_name: "Novice",
        level_description: "Basic level",
        skill_code: ""
      },
      overrides
    )
  end

  describe "ensure_company/1" do
    test "creates a new company" do
      assert {:ok, company} = SkillStore.ensure_company("test_co")
      assert company.id == "test_co"
    end

    test "is idempotent — second call does not crash" do
      assert {:ok, first} = SkillStore.ensure_company("test_co")
      assert first.id == "test_co"
      assert {:ok, _} = SkillStore.ensure_company("test_co")
    end
  end

  describe "save_framework/1 + get_framework_rows/1" do
    test "creates new framework with rows" do
      SkillStore.ensure_company("test_co")

      {:ok, framework} =
        SkillStore.save_framework(%{
          name: "Test Framework",
          type: "company",
          company_id: "test_co",
          source: "test",
          rows: [
            full_row(%{
              role: "Data Analyst",
              skill_name: "Python",
              level: 1,
              level_name: "Novice",
              level_description: "Basic scripts"
            }),
            full_row(%{
              role: "Data Analyst",
              skill_name: "Python",
              level: 2,
              level_name: "Developing",
              level_description: "Builds pipelines"
            })
          ]
        })

      assert framework.id != nil
      assert framework.row_count == 2
      assert framework.skill_count == 1

      rows = SkillStore.get_framework_rows(framework.id)
      assert length(rows) == 2
      assert hd(rows).skill_name == "Python"
      assert hd(rows).role == "Data Analyst"
    end

    test "updates existing framework (replaces rows and name)" do
      SkillStore.ensure_company("test_co")

      {:ok, fw} =
        SkillStore.save_framework(%{
          name: "V1",
          type: "company",
          company_id: "test_co",
          rows: [full_row(%{skill_name: "SQL", role: "DA"})]
        })

      {:ok, fw2} =
        SkillStore.save_framework(%{
          id: fw.id,
          name: "V2",
          type: "company",
          company_id: "test_co",
          rows: [
            full_row(%{skill_name: "Python", role: "DE"}),
            full_row(%{skill_name: "SQL", role: "DE"})
          ]
        })

      assert fw2.id == fw.id
      assert fw2.name == "V2"
      rows = SkillStore.get_framework_rows(fw.id)
      assert length(rows) == 2
    end

    test "get_framework_rows returns empty list for nonexistent id" do
      assert SkillStore.get_framework_rows(999_999) == []
    end
  end

  describe "list_frameworks_for/3" do
    setup do
      SkillStore.ensure_company("co_a")
      SkillStore.ensure_company("co_b")

      SkillStore.save_framework(%{
        name: "AICB",
        type: "industry",
        company_id: nil,
        rows: [full_row(%{skill_name: "Risk Mgmt"})]
      })

      SkillStore.save_framework(%{
        name: "Co A Framework",
        type: "company",
        company_id: "co_a",
        rows: [full_row(%{skill_name: "Python", role: "DA"})]
      })

      SkillStore.save_framework(%{
        name: "Co B Framework",
        type: "company",
        company_id: "co_b",
        rows: [full_row(%{skill_name: "SQL", role: "DE"})]
      })

      :ok
    end

    test "admin sees everything" do
      frameworks = SkillStore.list_frameworks_for(nil, true)
      names = Enum.map(frameworks, & &1.name) |> Enum.sort()
      assert names == ["AICB", "Co A Framework", "Co B Framework"]
    end

    test "company user sees industry + own company only" do
      frameworks = SkillStore.list_frameworks_for("co_a", false)
      names = Enum.map(frameworks, & &1.name)
      assert "AICB" in names
      assert "Co A Framework" in names
      refute "Co B Framework" in names
    end

    test "non-admin with nil company sees only industry" do
      frameworks = SkillStore.list_frameworks_for(nil, false)
      names = Enum.map(frameworks, & &1.name)
      assert names == ["AICB"]
    end

    test "type filter works" do
      frameworks = SkillStore.list_frameworks_for("co_a", false, "industry")
      assert length(frameworks) == 1
      assert hd(frameworks).name == "AICB"
    end

    test "includes roles in response" do
      frameworks = SkillStore.list_frameworks_for("co_a", false, "company")
      co_a = Enum.find(frameworks, &(&1.name == "Co A Framework"))
      assert co_a != nil
      assert "DA" in co_a.roles
    end
  end
end
