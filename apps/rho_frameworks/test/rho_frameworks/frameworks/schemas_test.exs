defmodule RhoFrameworks.Frameworks.SchemasTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.Frameworks.{Library, Skill, RoleProfile, RoleSkill, DuplicateDismissal}

  @org_id Ecto.UUID.generate()

  describe "Library.changeset/2" do
    test "valid with name and organization_id" do
      cs = Library.changeset(%Library{}, %{name: "SFIA v8", organization_id: @org_id})
      assert cs.valid?
    end

    test "defaults type to skill and immutable to false" do
      cs = Library.changeset(%Library{}, %{name: "Test", organization_id: @org_id})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :type) == "skill"
      assert Ecto.Changeset.get_field(cs, :immutable) == false
    end

    test "invalid without name" do
      cs = Library.changeset(%Library{}, %{organization_id: @org_id})
      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "invalid with unsupported type" do
      cs =
        Library.changeset(%Library{}, %{
          name: "Test",
          organization_id: @org_id,
          type: "invalid"
        })

      refute cs.valid?
      assert errors_on(cs)[:type]
    end
  end

  describe "Skill.changeset/2" do
    @lib_id Ecto.UUID.generate()

    test "valid with name, category, and library_id" do
      cs =
        Skill.changeset(%Skill{}, %{
          name: "SQL",
          category: "Technical",
          library_id: @lib_id
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :slug) == "sql"
    end

    test "generates slug from name" do
      cs =
        Skill.changeset(%Skill{}, %{
          name: "Data Modeling & Design",
          category: "Technical",
          library_id: @lib_id
        })

      assert Ecto.Changeset.get_change(cs, :slug) == "data-modeling-design"
    end

    test "defaults status to draft" do
      cs =
        Skill.changeset(%Skill{}, %{
          name: "SQL",
          category: "Technical",
          library_id: @lib_id
        })

      assert Ecto.Changeset.get_field(cs, :status) == "draft"
    end

    test "invalid without name" do
      cs = Skill.changeset(%Skill{}, %{category: "Technical", library_id: @lib_id})
      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "invalid with bad status" do
      cs =
        Skill.changeset(%Skill{}, %{
          name: "SQL",
          category: "Technical",
          library_id: @lib_id,
          status: "banana"
        })

      refute cs.valid?
      assert errors_on(cs)[:status]
    end

    test "accepts proficiency_levels as list of maps" do
      levels = [
        %{level: 1, level_name: "Basic", level_description: "Can write simple queries"},
        %{level: 2, level_name: "Intermediate", level_description: "Joins and subqueries"}
      ]

      cs =
        Skill.changeset(%Skill{}, %{
          name: "SQL",
          category: "Technical",
          library_id: @lib_id,
          proficiency_levels: levels
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :proficiency_levels) == levels
    end
  end

  describe "RoleProfile.changeset/2" do
    test "valid with only name and organization_id" do
      cs =
        RoleProfile.changeset(%RoleProfile{}, %{
          name: "Senior Data Engineer",
          organization_id: @org_id
        })

      assert cs.valid?
    end

    test "all rich fields are optional" do
      cs =
        RoleProfile.changeset(%RoleProfile{}, %{name: "Test Role", organization_id: @org_id})

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :purpose) == nil
      assert Ecto.Changeset.get_field(cs, :accountabilities) == nil
      assert Ecto.Changeset.get_field(cs, :success_metrics) == nil
    end

    test "invalid without name" do
      cs = RoleProfile.changeset(%RoleProfile{}, %{organization_id: @org_id})
      refute cs.valid?
      assert errors_on(cs)[:name]
    end
  end

  describe "RoleSkill.changeset/2" do
    @rp_id Ecto.UUID.generate()
    @skill_id Ecto.UUID.generate()

    test "valid with required fields" do
      cs =
        RoleSkill.changeset(%RoleSkill{}, %{
          min_expected_level: 3,
          role_profile_id: @rp_id,
          skill_id: @skill_id
        })

      assert cs.valid?
    end

    test "defaults weight to 1.0 and required to true" do
      cs =
        RoleSkill.changeset(%RoleSkill{}, %{
          min_expected_level: 3,
          role_profile_id: @rp_id,
          skill_id: @skill_id
        })

      assert Ecto.Changeset.get_field(cs, :weight) == 1.0
      assert Ecto.Changeset.get_field(cs, :required) == true
    end

    test "invalid with level <= 0" do
      cs =
        RoleSkill.changeset(%RoleSkill{}, %{
          min_expected_level: 0,
          role_profile_id: @rp_id,
          skill_id: @skill_id
        })

      refute cs.valid?
      assert errors_on(cs)[:min_expected_level]
    end
  end

  describe "DuplicateDismissal.changeset/2" do
    @lib_id Ecto.UUID.generate()
    @sa_id Ecto.UUID.generate()
    @sb_id Ecto.UUID.generate()

    test "valid with all required fields" do
      cs =
        DuplicateDismissal.changeset(%DuplicateDismissal{}, %{
          library_id: @lib_id,
          skill_a_id: @sa_id,
          skill_b_id: @sb_id
        })

      assert cs.valid?
    end

    test "invalid without library_id" do
      cs =
        DuplicateDismissal.changeset(%DuplicateDismissal{}, %{
          skill_a_id: @sa_id,
          skill_b_id: @sb_id
        })

      refute cs.valid?
      assert errors_on(cs)[:library_id]
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
