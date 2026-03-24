defmodule Rho.SkillTest do
  use ExUnit.Case, async: true

  alias Rho.Skill

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "rho_skill_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  defp create_skill(tmp_dir, name, opts \\ []) do
    desc = Keyword.get(opts, :description, "A test skill")
    body = Keyword.get(opts, :body, "Do the thing.")
    metadata = Keyword.get(opts, :metadata)

    dir = Path.join(tmp_dir, name)
    File.mkdir_p!(dir)

    metadata_line = if metadata, do: "metadata:\n  #{metadata}\n", else: ""

    content = """
    ---
    name: #{name}
    description: #{desc}
    #{metadata_line}---
    #{body}
    """

    File.write!(Path.join(dir, "SKILL.md"), content)
    dir
  end

  describe "parse_skill_md/2" do
    test "parses a valid SKILL.md", %{tmp_dir: tmp_dir} do
      dir = create_skill(tmp_dir, "my-skill", description: "Does things", body: "Step 1: do it.")
      path = Path.join(dir, "SKILL.md")

      assert {:ok, skill} = Skill.parse_skill_md(path, "project")
      assert skill.name == "my-skill"
      assert skill.description == "Does things"
      assert skill.source == "project"
      assert skill.body == "Step 1: do it."
      assert skill.metadata == %{}
    end

    test "rejects missing frontmatter", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "bad-skill")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "Just some markdown\n")

      assert {:error, :no_frontmatter} = Skill.parse_skill_md(Path.join(dir, "SKILL.md"), "project")
    end

    test "rejects invalid name pattern", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "Bad_Name")
      File.mkdir_p!(dir)

      content = """
      ---
      name: Bad_Name
      description: Invalid
      ---
      body
      """

      File.write!(Path.join(dir, "SKILL.md"), content)

      assert {:error, :invalid_frontmatter} = Skill.parse_skill_md(Path.join(dir, "SKILL.md"), "project")
    end

    test "rejects missing description", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "no-desc")
      File.mkdir_p!(dir)

      content = """
      ---
      name: no-desc
      ---
      body
      """

      File.write!(Path.join(dir, "SKILL.md"), content)

      assert {:error, :invalid_frontmatter} = Skill.parse_skill_md(Path.join(dir, "SKILL.md"), "project")
    end
  end

  describe "discover/1" do
    test "discovers skills from a workspace directory", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      skills_dir = Path.join(workspace, ".agents/skills")
      File.mkdir_p!(skills_dir)

      # Create two skills
      for name <- ["alpha", "beta"] do
        dir = Path.join(skills_dir, name)
        File.mkdir_p!(dir)

        File.write!(Path.join(dir, "SKILL.md"), """
        ---
        name: #{name}
        description: The #{name} skill
        ---
        Do #{name} things.
        """)
      end

      skills = Skill.discover(workspace)
      assert length(skills) == 2
      assert Enum.map(skills, & &1.name) == ["alpha", "beta"]
      assert Enum.all?(skills, &(&1.source == "project"))
    end

    test "returns empty list when no skills directory exists", %{tmp_dir: tmp_dir} do
      assert [] = Skill.discover(Path.join(tmp_dir, "nonexistent"))
    end

    test "skips directories without SKILL.md", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace2")
      skills_dir = Path.join(workspace, ".agents/skills")
      empty_dir = Path.join(skills_dir, "empty-skill")
      File.mkdir_p!(empty_dir)

      assert [] = Skill.discover(workspace)
    end

    test "deduplicates by name (first source wins)", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace3")

      # Create same skill in project scope
      proj_dir = Path.join([workspace, ".agents/skills/dupe-skill"])
      File.mkdir_p!(proj_dir)

      File.write!(Path.join(proj_dir, "SKILL.md"), """
      ---
      name: dupe-skill
      description: Project version
      ---
      Project body.
      """)

      skills = Skill.discover(workspace)
      assert length(skills) == 1
      assert hd(skills).description == "Project version"
    end
  end

  describe "render_prompt/2" do
    test "renders summary of skills" do
      skills = [
        %Skill{name: "alpha", description: "Does alpha", location: "/a", source: "project", body: "Alpha body"},
        %Skill{name: "beta", description: "Does beta", location: "/b", source: "global", body: "Beta body"}
      ]

      result = Skill.render_prompt(skills)
      assert result =~ "<available_skills>"
      assert result =~ "- alpha: Does alpha"
      assert result =~ "- beta: Does beta"
      assert result =~ "</available_skills>"
      refute result =~ "Alpha body"
    end

    test "includes expanded skill bodies" do
      skills = [
        %Skill{name: "alpha", description: "Does alpha", location: "/a", source: "project", body: "Alpha body"},
        %Skill{name: "beta", description: "Does beta", location: "/b", source: "global", body: "Beta body"}
      ]

      expanded = MapSet.new(["alpha"])
      result = Skill.render_prompt(skills, expanded)

      assert result =~ "## Skill: alpha"
      assert result =~ "Alpha body"
      refute result =~ "Beta body"
    end
  end

  describe "expanded_hints/2" do
    test "detects skill references in prompt" do
      skills = [
        %Skill{name: "alpha", description: "d", location: "/a", source: "p", body: "b"},
        %Skill{name: "beta", description: "d", location: "/b", source: "p", body: "b"}
      ]

      hints = Skill.expanded_hints("Please use $alpha for this task", skills)
      assert MapSet.member?(hints, "alpha")
      refute MapSet.member?(hints, "beta")
    end

    test "returns empty set when no references" do
      skills = [
        %Skill{name: "alpha", description: "d", location: "/a", source: "p", body: "b"}
      ]

      assert MapSet.new() == Skill.expanded_hints("no references here", skills)
    end
  end
end
