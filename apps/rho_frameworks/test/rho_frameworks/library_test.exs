defmodule RhoFrameworks.LibraryTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Frameworks.{Library, Skill}

  setup do
    # Create org
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "Test Org",
      slug: "test-org-#{System.unique_integer([:positive])}"
    })

    %{org_id: org_id}
  end

  describe "create_library/2" do
    test "creates a mutable library", %{org_id: org_id} do
      {:ok, lib} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "Engineering Skills",
          description: "Tech skills"
        })

      assert lib.name == "Engineering Skills"
      assert lib.immutable == false
      assert lib.type == "skill"
      assert lib.organization_id == org_id
    end
  end

  describe "get_or_create_default_library/1" do
    test "creates on first call, returns existing on second", %{org_id: org_id} do
      lib1 = RhoFrameworks.Library.get_or_create_default_library(org_id)
      lib2 = RhoFrameworks.Library.get_or_create_default_library(org_id)
      assert lib1.id == lib2.id
      assert lib1.name == "Default Skills"
    end
  end

  describe "ensure_mutable!/1" do
    test "passes for mutable library" do
      assert :ok == RhoFrameworks.Library.ensure_mutable!(%Library{immutable: false})
    end

    test "rejects immutable library" do
      assert {:error, :immutable_library, msg} =
               RhoFrameworks.Library.ensure_mutable!(%Library{immutable: true, name: "SFIA"})

      assert msg =~ "Cannot modify"
    end
  end

  describe "upsert_skill/2" do
    test "creates a new skill with slug", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Test Lib"})

      {:ok, skill} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{
          name: "SQL Programming",
          category: "Technical",
          cluster: "Data"
        })

      assert skill.slug == "sql-programming"
      assert skill.status == "draft"
    end

    test "upserts by slug — second call updates", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Test Lib"})

      {:ok, s1} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{
          name: "SQL",
          category: "Technical",
          description: "v1"
        })

      {:ok, s2} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{
          name: "SQL",
          category: "Technical",
          description: "v2"
        })

      assert s1.id == s2.id
      assert s2.description == "v2"
    end

    test "does not downgrade published to draft", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Test Lib"})

      {:ok, _} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{
          name: "SQL",
          category: "Technical",
          status: "published"
        })

      {:ok, s2} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{
          name: "SQL",
          category: "Technical",
          status: "draft"
        })

      assert s2.status == "published"
    end

    test "rejects writes to immutable library", %{org_id: org_id} do
      {:ok, lib} =
        RhoFrameworks.Library.create_library(org_id, %{name: "Immutable", immutable: true})

      assert {:error, :immutable_library, _} =
               RhoFrameworks.Library.upsert_skill(lib.id, %{
                 name: "SQL",
                 category: "Technical"
               })
    end
  end

  describe "save_to_library/2" do
    test "saves structured skill maps with nested proficiency levels", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Test Lib"})

      skills = [
        %{
          category: "Technical",
          cluster: "Data",
          skill_name: "SQL",
          skill_description: "Query lang",
          proficiency_levels: [
            %{"level" => 1, "level_name" => "Basic", "level_description" => "Simple queries"},
            %{"level" => 2, "level_name" => "Intermediate", "level_description" => "Joins"}
          ]
        },
        %{
          category: "Technical",
          cluster: "Data",
          skill_name: "Python",
          skill_description: "Programming",
          proficiency_levels: [
            %{"level" => 1, "level_name" => "Basic", "level_description" => "Scripts"}
          ]
        }
      ]

      {:ok, %{skills: result}} = RhoFrameworks.Library.save_to_library(lib.id, skills)

      assert length(result) == 2

      sql_skill = Enum.find(result, fn skill -> skill.name == "SQL" end)
      assert sql_skill.status == "published"
      assert length(sql_skill.proficiency_levels) == 2
    end
  end

  describe "fork_library/4" do
    test "deep-copies skills with source_skill_id lineage", %{org_id: org_id} do
      {:ok, source} =
        RhoFrameworks.Library.create_library(org_id, %{name: "Source Lib", immutable: true})

      {:ok, skill} =
        %Skill{}
        |> Skill.changeset(%{
          name: "SQL",
          category: "Technical",
          library_id: source.id,
          status: "published"
        })
        |> Repo.insert()

      {:ok, %{library: fork, skills: skill_map}} =
        RhoFrameworks.Library.fork_library(org_id, source.id, "My Fork", include_roles: false)

      assert fork.derived_from_id == source.id
      assert fork.immutable == false
      assert map_size(skill_map) == 1

      forked_skill = skill_map[skill.id]
      assert forked_skill.name == "SQL"
      assert forked_skill.source_skill_id == skill.id
      assert forked_skill.library_id == fork.id
    end
  end

  describe "diff_against_source/2" do
    test "detects added and unchanged skills", %{org_id: org_id} do
      {:ok, source} =
        RhoFrameworks.Library.create_library(org_id, %{name: "Diff Source", immutable: true})

      {:ok, _} =
        %Skill{}
        |> Skill.changeset(%{
          name: "SQL",
          category: "Tech",
          library_id: source.id,
          status: "published"
        })
        |> Repo.insert()

      {:ok, %{library: fork}} =
        RhoFrameworks.Library.fork_library(org_id, source.id, "Diff Fork", include_roles: false)

      # Add a new skill to the fork
      {:ok, _} =
        RhoFrameworks.Library.upsert_skill(fork.id, %{name: "Rust", category: "Tech"})

      {:ok, diff} = RhoFrameworks.Library.diff_against_source(org_id, fork.id)

      assert "Rust" in diff.added
      assert diff.unchanged_count == 1
    end
  end

  describe "find_duplicates/2" do
    test "detects slug prefix overlaps", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Dedup Lib"})

      for name <- ["SQL Programming", "SQL Querying"] do
        RhoFrameworks.Library.upsert_skill(lib.id, %{name: name, category: "Technical"})
      end

      dupes = RhoFrameworks.Library.find_duplicates(lib.id)
      assert dupes != []
      assert hd(dupes).confidence == :high
    end
  end

  describe "dismiss_duplicate/3" do
    test "dismissed pairs are excluded from find_duplicates", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Dismiss Lib"})

      {:ok, s1} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{name: "SQL Programming", category: "Tech"})

      {:ok, s2} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{name: "SQL Querying", category: "Tech"})

      dupes_before = RhoFrameworks.Library.find_duplicates(lib.id)
      assert dupes_before != []

      RhoFrameworks.Library.dismiss_duplicate(lib.id, s1.id, s2.id)

      dupes_after = RhoFrameworks.Library.find_duplicates(lib.id)
      assert dupes_after == []
    end
  end

  describe "load_template/3" do
    test "creates immutable library with skills and role profiles", %{org_id: org_id} do
      template_data = %{
        name: "Test Framework",
        description: "A test framework",
        skills: [
          %{
            category: "Tech",
            cluster: "Data",
            name: "SQL",
            description: "Query language",
            proficiency_levels: [
              %{"level" => 1, "level_name" => "Basic", "level_description" => "Simple queries"}
            ]
          },
          %{
            category: "Tech",
            cluster: "Dev",
            name: "Python",
            description: "Programming",
            proficiency_levels: [
              %{"level" => 1, "level_name" => "Basic", "level_description" => "Scripts"}
            ]
          }
        ],
        role_profiles: [
          %{
            name: "Data Engineer",
            role_family: "Engineering",
            seniority_level: 3,
            seniority_label: "Senior",
            purpose: "Builds data pipelines",
            skills: [
              %{skill_name: "SQL", min_expected_level: 4, required: true},
              %{skill_name: "Python", min_expected_level: 3, required: false}
            ]
          }
        ]
      }

      {:ok, result} = RhoFrameworks.Library.load_template(org_id, "test_fw", template_data)

      assert result.library.immutable == true
      assert result.library.source_key == "test_fw"
      assert length(result.skills) == 2
      assert length(result.role_profiles) == 1

      rp = hd(result.role_profiles)
      assert rp.name == "Data Engineer"
      assert rp.immutable == true

      # Role skills should be created
      rp_loaded = Repo.preload(rp, role_skills: :skill)
      assert length(rp_loaded.role_skills) == 2

      sql_rs = Enum.find(rp_loaded.role_skills, &(&1.skill.name == "SQL"))
      assert sql_rs.min_expected_level == 4
      assert sql_rs.required == true
    end

    test "load_template without role_profiles still works", %{org_id: org_id} do
      template_data = %{
        name: "Skills Only",
        skills: [
          %{
            category: "Tech",
            name: "Rust",
            description: "Systems lang",
            proficiency_levels: []
          }
        ]
      }

      {:ok, result} = RhoFrameworks.Library.load_template(org_id, "skills_only", template_data)

      assert length(result.skills) == 1
      assert result.role_profiles == []
    end
  end

  describe "fork_library/4 with category filter" do
    test "only copies skills in selected categories", %{org_id: org_id} do
      {:ok, source} =
        RhoFrameworks.Library.create_library(org_id, %{name: "Multi-Cat Source", immutable: true})

      {:ok, _} =
        %Skill{}
        |> Skill.changeset(%{
          name: "SQL",
          category: "Data",
          library_id: source.id,
          status: "published"
        })
        |> Repo.insert()

      {:ok, _} =
        %Skill{}
        |> Skill.changeset(%{
          name: "Python",
          category: "Software Development",
          library_id: source.id,
          status: "published"
        })
        |> Repo.insert()

      {:ok, _} =
        %Skill{}
        |> Skill.changeset(%{
          name: "Leadership",
          category: "Management",
          library_id: source.id,
          status: "published"
        })
        |> Repo.insert()

      # Fork with only Data and Software Development categories
      {:ok, %{library: fork, skills: skill_map}} =
        RhoFrameworks.Library.fork_library(org_id, source.id, "Filtered Fork",
          include_roles: false,
          categories: ["Data", "Software Development"]
        )

      assert map_size(skill_map) == 2

      names = skill_map |> Map.values() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Python", "SQL"]
      assert fork.derived_from_id == source.id
    end

    test "category filter also filters role profiles to those with matching skills", %{
      org_id: org_id
    } do
      template_data = %{
        name: "Cat Filter Source",
        skills: [
          %{
            category: "Data",
            name: "SQL",
            description: "Queries",
            proficiency_levels: [
              %{"level" => 1, "level_name" => "Basic", "level_description" => "Simple"}
            ]
          },
          %{
            category: "Management",
            name: "Leadership",
            description: "Leading",
            proficiency_levels: [
              %{"level" => 1, "level_name" => "Basic", "level_description" => "Simple"}
            ]
          }
        ],
        role_profiles: [
          %{
            name: "Data Engineer",
            role_family: "Engineering",
            seniority_level: 2,
            skills: [%{skill_name: "SQL", min_expected_level: 3, required: true}]
          },
          %{
            name: "Manager",
            role_family: "Management",
            seniority_level: 3,
            skills: [%{skill_name: "Leadership", min_expected_level: 2, required: true}]
          }
        ]
      }

      {:ok, %{library: source}} =
        RhoFrameworks.Library.load_template(org_id, "cat_filter", template_data)

      # Fork only "Data" category
      {:ok, %{skills: skill_map, role_profiles: roles}} =
        RhoFrameworks.Library.fork_library(org_id, source.id, "Data Only Fork",
          categories: ["Data"]
        )

      assert map_size(skill_map) == 1
      assert hd(Map.values(skill_map)).name == "SQL"

      # Only Data Engineer should be copied (it has a skill in "Data" category)
      role_names = Enum.map(roles, & &1.name)
      assert length(roles) == 1
      assert hd(role_names) =~ "Data Engineer"
    end
  end

  describe "fork_library/4 with role profiles" do
    test "deep-copies role profiles with remapped skill FKs", %{org_id: org_id} do
      template_data = %{
        name: "Fork Source",
        skills: [
          %{
            category: "Tech",
            name: "SQL",
            description: "Queries",
            proficiency_levels: [
              %{"level" => 1, "level_name" => "Basic", "level_description" => "Simple"}
            ]
          }
        ],
        role_profiles: [
          %{
            name: "DBA",
            role_family: "Engineering",
            seniority_level: 2,
            skills: [%{skill_name: "SQL", min_expected_level: 3, required: true}]
          }
        ]
      }

      {:ok, %{library: source}} =
        RhoFrameworks.Library.load_template(org_id, "fork_src", template_data)

      {:ok, %{library: fork, skills: skill_map, role_profiles: roles}} =
        RhoFrameworks.Library.fork_library(org_id, source.id, "My Fork")

      assert fork.immutable == false
      assert map_size(skill_map) == 1
      assert length(roles) == 1

      forked_rp = hd(roles)
      assert forked_rp.name == "DBA (My Fork)"
      assert forked_rp.immutable == false
      assert forked_rp.source_role_profile_id != nil

      # Role skill should point to forked skill, not source skill
      forked_rp_loaded = Repo.preload(forked_rp, role_skills: :skill)
      rs = hd(forked_rp_loaded.role_skills)
      assert rs.skill.library_id == fork.id
    end
  end

  describe "load_library_rows/2" do
    test "returns structured skill maps with nested proficiency_levels", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Structured Lib"})

      {:ok, skill} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{
          name: "SQL",
          category: "Tech",
          cluster: "Data",
          description: "Query language"
        })

      skill
      |> Skill.changeset(%{
        proficiency_levels: [
          %{level: 1, level_name: "Basic", level_description: "Simple queries"},
          %{level: 2, level_name: "Intermediate", level_description: "Joins and subqueries"}
        ]
      })
      |> Repo.update!()

      rows = RhoFrameworks.Library.load_library_rows(lib.id)

      assert length(rows) == 1

      row = hd(rows)
      assert row.skill_name == "SQL"
      assert row.category == "Tech"
      assert row.cluster == "Data"
      assert length(row.proficiency_levels) == 2
    end

    test "skills without proficiency levels return empty list", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "No Levels Lib"})

      RhoFrameworks.Library.upsert_skill(lib.id, %{
        name: "Rust",
        category: "Tech",
        description: "Systems lang"
      })

      rows = RhoFrameworks.Library.load_library_rows(lib.id)

      assert length(rows) == 1
      assert hd(rows).skill_name == "Rust"
      assert hd(rows).proficiency_levels == []
    end

    test "respects category filter", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Filter Lib"})

      RhoFrameworks.Library.upsert_skill(lib.id, %{name: "SQL", category: "Data"})
      RhoFrameworks.Library.upsert_skill(lib.id, %{name: "Leadership", category: "Soft"})

      rows = RhoFrameworks.Library.load_library_rows(lib.id, category: "Data")

      assert length(rows) == 1
      assert hd(rows).skill_name == "SQL"
    end
  end

  describe "consolidation_report/1" do
    test "detects duplicate pairs", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Consol Lib"})

      RhoFrameworks.Library.upsert_skill(lib.id, %{
        name: "SQL Programming",
        category: "Tech",
        status: "published"
      })

      RhoFrameworks.Library.upsert_skill(lib.id, %{
        name: "SQL Querying",
        category: "Tech",
        status: "published"
      })

      report = RhoFrameworks.Library.consolidation_report(lib.id)

      assert report.total_skills == 2
      assert report.duplicate_pairs != []
    end

    test "surfaces draft skills sorted by role count", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Draft Lib"})

      # Create draft skills via role profile save
      rows = [
        %{category: "Tech", skill_name: "Elixir", required_level: 3},
        %{category: "Tech", skill_name: "Phoenix", required_level: 2}
      ]

      RhoFrameworks.Roles.save_role_profile(org_id, %{name: "Dev"}, rows, library_id: lib.id)

      # Create a second role referencing Elixir
      rows2 = [%{category: "Tech", skill_name: "Elixir", required_level: 4}]

      RhoFrameworks.Roles.save_role_profile(org_id, %{name: "Sr Dev"}, rows2, library_id: lib.id)

      report = RhoFrameworks.Library.consolidation_report(lib.id)

      assert length(report.drafts) == 2
      # Elixir should be first (2 role references > 1)
      first_draft = hd(report.drafts)
      assert first_draft.name == "Elixir"
      assert first_draft.role_count == 2
    end

    test "detects orphan skills with no role references", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Orphan Lib"})

      RhoFrameworks.Library.upsert_skill(lib.id, %{
        name: "Orphan Skill",
        category: "Tech",
        status: "published"
      })

      report = RhoFrameworks.Library.consolidation_report(lib.id)

      assert length(report.orphans) == 1
      assert hd(report.orphans).name == "Orphan Skill"
    end
  end

  describe "find_duplicates/2 role reference enrichment" do
    test "includes roles_a, roles_b, and level_conflict", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Enrich Lib"})

      # Create two similar skills
      {:ok, s1} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{name: "SQL Programming", category: "Tech"})

      {:ok, s2} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{name: "SQL Querying", category: "Tech"})

      # Create role profiles referencing these skills
      RhoFrameworks.Roles.save_role_profile(
        org_id,
        %{name: "Data Engineer"},
        [%{category: "Tech", skill_name: "SQL Programming", required_level: 4}],
        library_id: lib.id
      )

      RhoFrameworks.Roles.save_role_profile(
        org_id,
        %{name: "ML Engineer"},
        [%{category: "Tech", skill_name: "SQL Querying", required_level: 3}],
        library_id: lib.id
      )

      dupes = RhoFrameworks.Library.find_duplicates(lib.id)
      assert dupes != []

      pair = hd(dupes)
      assert is_list(pair.roles_a)
      assert is_list(pair.roles_b)
      assert is_boolean(pair.level_conflict)

      # Each skill is referenced by one role
      all_roles = pair.roles_a ++ pair.roles_b
      assert "Data Engineer" in all_roles
      assert "ML Engineer" in all_roles
    end

    test "level_conflict is true when shared role has different levels", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Conflict Lib"})

      # Create two similar skills
      RhoFrameworks.Library.upsert_skill(lib.id, %{name: "SQL Programming", category: "Tech"})
      RhoFrameworks.Library.upsert_skill(lib.id, %{name: "SQL Querying", category: "Tech"})

      # Same role references both skills at different levels
      RhoFrameworks.Roles.save_role_profile(
        org_id,
        %{name: "DBA"},
        [
          %{category: "Tech", skill_name: "SQL Programming", required_level: 4},
          %{category: "Tech", skill_name: "SQL Querying", required_level: 2}
        ],
        library_id: lib.id
      )

      dupes = RhoFrameworks.Library.find_duplicates(lib.id)
      pair = hd(dupes)

      assert pair.level_conflict == true
      assert "DBA" in pair.roles_a
      assert "DBA" in pair.roles_b
    end
  end

  describe "merge_skills/3" do
    setup %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Merge Lib"})

      {:ok, s1} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{
          name: "SQL Programming",
          category: "Tech",
          status: "published"
        })

      {:ok, s2} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{
          name: "SQL Querying",
          category: "Tech",
          status: "published"
        })

      %{lib: lib, source: s1, target: s2}
    end

    test "repoints clean role references to target", %{
      org_id: org_id,
      lib: lib,
      source: source,
      target: target
    } do
      # Different roles reference different skills — no conflict
      RhoFrameworks.Roles.save_role_profile(
        org_id,
        %{name: "Data Engineer"},
        [%{category: "Tech", skill_name: "SQL Programming", required_level: 4}],
        library_id: lib.id
      )

      RhoFrameworks.Roles.save_role_profile(
        org_id,
        %{name: "ML Engineer"},
        [%{category: "Tech", skill_name: "SQL Querying", required_level: 3}],
        library_id: lib.id
      )

      {:ok, _result} = RhoFrameworks.Library.merge_skills(source.id, target.id)

      # Source should be deleted
      assert is_nil(Repo.get(Skill, source.id))

      # Target still exists and has both role references
      target_rs =
        Repo.all(from(rs in RhoFrameworks.Frameworks.RoleSkill, where: rs.skill_id == ^target.id))

      assert length(target_rs) == 2
    end

    test ":keep_higher conflict strategy takes max level", %{
      org_id: org_id,
      lib: lib,
      source: source,
      target: target
    } do
      # Same role references both skills at different levels
      RhoFrameworks.Roles.save_role_profile(
        org_id,
        %{name: "DBA"},
        [
          %{category: "Tech", skill_name: "SQL Programming", required_level: 5},
          %{category: "Tech", skill_name: "SQL Querying", required_level: 3}
        ],
        library_id: lib.id
      )

      {:ok, _result} =
        RhoFrameworks.Library.merge_skills(source.id, target.id, on_conflict: :keep_higher)

      # Source deleted
      assert is_nil(Repo.get(Skill, source.id))

      # Target's role_skill should have the higher level (5)
      [rs] =
        Repo.all(from(rs in RhoFrameworks.Frameworks.RoleSkill, where: rs.skill_id == ^target.id))

      assert rs.min_expected_level == 5
    end

    test ":keep_target conflict strategy keeps target level", %{
      org_id: org_id,
      lib: lib,
      source: source,
      target: target
    } do
      RhoFrameworks.Roles.save_role_profile(
        org_id,
        %{name: "DBA"},
        [
          %{category: "Tech", skill_name: "SQL Programming", required_level: 5},
          %{category: "Tech", skill_name: "SQL Querying", required_level: 3}
        ],
        library_id: lib.id
      )

      {:ok, _result} =
        RhoFrameworks.Library.merge_skills(source.id, target.id, on_conflict: :keep_target)

      assert is_nil(Repo.get(Skill, source.id))

      [rs] =
        Repo.all(from(rs in RhoFrameworks.Frameworks.RoleSkill, where: rs.skill_id == ^target.id))

      # keep_target: target level (3) wins
      assert rs.min_expected_level == 3
    end

    test ":flag conflict strategy returns conflicts without resolving", %{
      org_id: org_id,
      lib: lib,
      source: source,
      target: target
    } do
      RhoFrameworks.Roles.save_role_profile(
        org_id,
        %{name: "DBA"},
        [
          %{category: "Tech", skill_name: "SQL Programming", required_level: 5},
          %{category: "Tech", skill_name: "SQL Querying", required_level: 3}
        ],
        library_id: lib.id
      )

      {:ok, result} =
        RhoFrameworks.Library.merge_skills(source.id, target.id, on_conflict: :flag)

      # Conflicts are returned as tuples
      assert [{:conflict, _source_rs, _target_rs}] = result.conflicts
    end

    test "rename on merge", %{source: source, target: target} do
      {:ok, _result} =
        RhoFrameworks.Library.merge_skills(source.id, target.id, new_name: "SQL")

      updated = Repo.get!(Skill, target.id)
      assert updated.name == "SQL"
    end
  end

  describe "merge_skills/3 proficiency level gap-fill" do
    test "fills gaps from source without overwriting target levels", %{org_id: org_id} do
      {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Level Lib"})

      # Source has levels 1 and 2
      {:ok, source} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{
          name: "SQL Programming",
          category: "Tech"
        })

      source
      |> Skill.changeset(%{
        proficiency_levels: [
          %{level: 1, level_name: "Basic", level_description: "Source basic"},
          %{level: 2, level_name: "Intermediate", level_description: "Source intermediate"}
        ]
      })
      |> Repo.update!()

      # Target has level 2 (different description) and level 3
      {:ok, target} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{
          name: "SQL Querying",
          category: "Tech"
        })

      target
      |> Skill.changeset(%{
        proficiency_levels: [
          %{level: 2, level_name: "Mid", level_description: "Target mid"},
          %{level: 3, level_name: "Advanced", level_description: "Target advanced"}
        ]
      })
      |> Repo.update!()

      {:ok, result} = RhoFrameworks.Library.merge_skills(source.id, target.id)

      # Should have filled 1 gap (level 1 from source)
      assert result.levels.filled == 1
      assert result.levels.total == 3

      # Verify target now has all 3 levels
      merged = Repo.get!(Skill, target.id)
      assert length(merged.proficiency_levels) == 3

      # Level 2 should keep target's description (target wins)
      level_2 =
        Enum.find(merged.proficiency_levels, fn l ->
          (l["level"] || l[:level]) == 2
        end)

      desc = level_2["level_description"] || level_2[:level_description]
      assert desc == "Target mid"
    end
  end

  describe "combine_libraries/4" do
    test "copies skills from multiple sources into a new library", %{org_id: org_id} do
      {:ok, lib_a} = RhoFrameworks.Library.create_library(org_id, %{name: "Lib A"})
      {:ok, lib_b} = RhoFrameworks.Library.create_library(org_id, %{name: "Lib B"})

      RhoFrameworks.Library.upsert_skill(lib_a.id, %{name: "SQL", category: "Tech"})
      RhoFrameworks.Library.upsert_skill(lib_a.id, %{name: "Python", category: "Tech"})
      RhoFrameworks.Library.upsert_skill(lib_b.id, %{name: "Leadership", category: "Soft"})

      {:ok, %{library: combined, skill_count: count}} =
        RhoFrameworks.Library.combine_libraries(
          org_id,
          [lib_a.id, lib_b.id],
          "Combined Skills"
        )

      assert count == 3
      assert combined.immutable == false
      assert combined.description =~ "Lib A"
      assert combined.description =~ "Lib B"

      skills = RhoFrameworks.Library.list_skills(combined.id)
      names = Enum.map(skills, & &1.name) |> Enum.sort()
      assert names == ["Leadership", "Python", "SQL"]
    end

    test "sources are not modified", %{org_id: org_id} do
      {:ok, lib_a} = RhoFrameworks.Library.create_library(org_id, %{name: "Source"})
      RhoFrameworks.Library.upsert_skill(lib_a.id, %{name: "SQL", category: "Tech"})

      {:ok, _} =
        RhoFrameworks.Library.combine_libraries(org_id, [lib_a.id], "Copy")

      # Source still has its skill
      assert length(RhoFrameworks.Library.list_skills(lib_a.id)) == 1
    end

    test "combined library surfaces duplicates from different sources", %{org_id: org_id} do
      {:ok, lib_a} = RhoFrameworks.Library.create_library(org_id, %{name: "Team A"})
      {:ok, lib_b} = RhoFrameworks.Library.create_library(org_id, %{name: "Team B"})

      # Similar skill names across libraries
      RhoFrameworks.Library.upsert_skill(lib_a.id, %{name: "SQL Programming", category: "Tech"})
      RhoFrameworks.Library.upsert_skill(lib_b.id, %{name: "SQL Querying", category: "Tech"})

      {:ok, %{library: combined}} =
        RhoFrameworks.Library.combine_libraries(
          org_id,
          [lib_a.id, lib_b.id],
          "Merged"
        )

      dupes = RhoFrameworks.Library.find_duplicates(combined.id)
      assert dupes != []
    end
  end
end
