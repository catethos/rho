defmodule RhoFrameworks.Library.SkeletonsTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.Library.Skeletons

  describe "parse_json/1" do
    test "parses valid JSON array of skills" do
      json =
        ~s([{"skill_name":"SQL","category":"Data","cluster":"DB","skill_description":"Querying"}])

      assert {:ok, [%{"skill_name" => "SQL", "category" => "Data"}]} = Skeletons.parse_json(json)
    end

    test "parses multiple skills" do
      json =
        Jason.encode!([
          %{skill_name: "SQL", category: "Data", cluster: "DB", skill_description: "Querying"},
          %{skill_name: "Elixir", category: "Dev", cluster: "Lang", skill_description: "BEAM"}
        ])

      assert {:ok, skills} = Skeletons.parse_json(json)
      assert match?([_, _], skills)
    end

    test "returns error for empty array" do
      assert {:error, :empty_list} = Skeletons.parse_json("[]")
    end

    test "returns error for non-array JSON" do
      assert {:error, :not_a_list} = Skeletons.parse_json(~s({"skill_name":"SQL"}))
    end

    test "returns error for invalid JSON" do
      assert {:error, {:json_decode, _}} = Skeletons.parse_json("not json")
    end

    test "returns error when required keys are missing" do
      json = ~s([{"skill_name":"SQL"}])
      assert {:error, {:missing_required_keys, _, 1}} = Skeletons.parse_json(json)
    end

    test "returns error when skill_name is empty" do
      json = ~s([{"skill_name":"","category":"Data"}])
      assert {:error, {:missing_required_keys, _, 1}} = Skeletons.parse_json(json)
    end
  end

  describe "to_rows/1" do
    test "normalizes skills into DataTable row shape" do
      skills = [
        %{
          "category" => "Data",
          "cluster" => "DB",
          "skill_name" => "SQL",
          "skill_description" => "Querying"
        }
      ]

      assert [row] = Skeletons.to_rows(skills)
      assert row.category == "Data"
      assert row.cluster == "DB"
      assert row.skill_name == "SQL"
      assert row.skill_description == "Querying"
      assert row.proficiency_levels == []
    end

    test "defaults missing fields to empty strings" do
      skills = [%{"skill_name" => "SQL", "category" => "Data"}]

      assert [row] = Skeletons.to_rows(skills)
      assert row.cluster == ""
      assert row.skill_description == ""
    end

    test "handles empty list" do
      assert [] = Skeletons.to_rows([])
    end
  end
end
