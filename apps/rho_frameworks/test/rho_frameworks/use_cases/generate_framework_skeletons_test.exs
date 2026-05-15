defmodule RhoFrameworks.UseCases.GenerateFrameworkSkeletonsTest do
  @moduledoc """
  Tests for the `Generate skill skeletons` UseCase. The LLM call is
  replaced via the `:generate_skeleton_fn` Application env so these run
  without hitting BAML / OpenRouter.
  """

  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{Repo, Scope}
  alias RhoFrameworks.UseCases.GenerateFrameworkSkeletons

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "GenSkel Test Org",
      slug: "genskel-test-#{System.unique_integer([:positive])}"
    })

    session_id = "sess-genskel-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:rho_frameworks, :generate_skeleton_fn)
      DataTable.stop(session_id)
    end)

    %{org_id: org_id, session_id: session_id}
  end

  defp scope(org_id, session_id, source \\ :flow) do
    %Scope{
      organization_id: org_id,
      session_id: session_id,
      user_id: "user-test",
      source: source,
      reason: "wizard:create-framework"
    }
  end

  defp put_seam(meta, skills) do
    Application.put_env(:rho_frameworks, :generate_skeleton_fn, fn _input, on_partial ->
      if meta, do: on_partial.(:meta, meta)
      Enum.each(skills, fn s -> on_partial.(:skill, s) end)
      {:ok, %{name: meta && meta.name, description: meta && meta.description, skills: skills}}
    end)
  end

  defp library_rows(session_id, table) do
    DataTable.get_rows(session_id, table: table)
  end

  defp meta_rows(session_id) do
    DataTable.get_rows(session_id, table: "meta")
  end

  describe "describe/0" do
    test "advertises the cheap one-shot UseCase" do
      assert %{id: :generate_framework_skeletons, cost_hint: :cheap} =
               GenerateFrameworkSkeletons.describe()
    end
  end

  describe "run/2 — happy path" do
    test "streams meta + skills via Workbench in order, stamps :flow source", %{
      org_id: org_id,
      session_id: session_id
    } do
      put_seam(%{name: "Engineering", description: "Eng framework"}, [
        %{
          category: "Engineering",
          cluster: "Tooling",
          name: "Vim",
          description: "Editor."
        },
        %{
          category: "Engineering",
          cluster: "Tooling",
          name: "Tmux",
          description: "Multiplexer."
        }
      ])

      assert {:ok, summary} =
               GenerateFrameworkSkeletons.run(
                 %{name: "Engineering", description: "Eng framework"},
                 scope(org_id, session_id)
               )

      assert summary.requested == 12
      assert summary.returned == 2
      assert summary.meta_set == true
      assert summary.table_name == "library:Engineering"
      assert summary.library_name == "Engineering"
      assert Enum.map(summary.added, & &1.name) == ["Vim", "Tmux"]

      rows = library_rows(session_id, "library:Engineering")
      names = Enum.map(rows, &Rho.MapAccess.get(&1, :skill_name))
      assert names == ["Vim", "Tmux"]

      sources = Enum.map(rows, &Rho.MapAccess.get(&1, :_source))
      assert Enum.all?(sources, &(&1 == "flow"))

      [meta] = meta_rows(session_id)
      assert (Rho.MapAccess.get(meta, :name)) == "Engineering"
      assert (Rho.MapAccess.get(meta, :description)) == "Eng framework"
    end

    test "duplicate skill_name partials are skipped silently", %{
      org_id: org_id,
      session_id: session_id
    } do
      put_seam(%{name: "Eng", description: "X"}, [
        %{category: "Eng", cluster: "T", name: "Vim", description: "Editor."},
        %{category: "Eng", cluster: "T", name: "Vim", description: "Editor."},
        %{category: "Eng", cluster: "T", name: "Tmux", description: "Multiplex."}
      ])

      assert {:ok, summary} =
               GenerateFrameworkSkeletons.run(
                 %{name: "Eng", description: "X"},
                 scope(org_id, session_id)
               )

      assert Enum.map(summary.added, & &1.name) == ["Vim", "Tmux"]

      names =
        session_id
        |> library_rows("library:Eng")
        |> Enum.map(&Rho.MapAccess.get(&1, :skill_name))

      assert names == ["Vim", "Tmux"]
    end

    test "skips skills missing required fields without crashing", %{
      org_id: org_id,
      session_id: session_id
    } do
      put_seam(%{name: "Eng", description: "X"}, [
        %{category: "Eng", cluster: "T", name: "Vim", description: ""},
        %{category: "Eng", cluster: "T", name: "Tmux", description: "Multiplex."}
      ])

      assert {:ok, summary} =
               GenerateFrameworkSkeletons.run(
                 %{name: "Eng", description: "X"},
                 scope(org_id, session_id)
               )

      assert Enum.map(summary.added, & &1.name) == ["Tmux"]
    end

    test "set_meta lands at most once even if seam re-emits :meta", %{
      org_id: org_id,
      session_id: session_id
    } do
      Application.put_env(:rho_frameworks, :generate_skeleton_fn, fn _input, on_partial ->
        on_partial.(:meta, %{name: "Eng", description: "X"})
        on_partial.(:meta, %{name: "Eng", description: "Y"})
        on_partial.(:skill, %{category: "C", cluster: "Cl", name: "S", description: "D."})
        {:ok, %{name: "Eng", description: "X", skills: [%{}]}}
      end)

      assert {:ok, _} =
               GenerateFrameworkSkeletons.run(
                 %{name: "Eng", description: "X"},
                 scope(org_id, session_id)
               )

      assert [meta] = meta_rows(session_id)
      # First write wins; second :meta call is a noop.
      assert (Rho.MapAccess.get(meta, :description)) == "X"
    end

    test "scope source is honoured (chat callers stamp :agent)", %{
      org_id: org_id,
      session_id: session_id
    } do
      put_seam(%{name: "Eng", description: "X"}, [
        %{category: "Eng", cluster: "T", name: "Vim", description: "Editor."}
      ])

      assert {:ok, _} =
               GenerateFrameworkSkeletons.run(
                 %{name: "Eng", description: "X"},
                 scope(org_id, session_id, :agent)
               )

      [row] = library_rows(session_id, "library:Eng")
      assert (Rho.MapAccess.get(row, :_source)) == "agent"
    end

    test "persists final result skills even when seam emits no partials", %{
      org_id: org_id,
      session_id: session_id
    } do
      Application.put_env(:rho_frameworks, :generate_skeleton_fn, fn _input, _on_partial ->
        {:ok,
         %{
           name: "Eng",
           description: "Built only from final result.",
           skills: [
             %{category: "C", cluster: "Cl", name: "Vim", description: "Editor."},
             %{category: "C", cluster: "Cl", name: "Tmux", description: "Multiplex."}
           ]
         }}
      end)

      assert {:ok, summary} =
               GenerateFrameworkSkeletons.run(
                 %{name: "Eng", description: "X"},
                 scope(org_id, session_id)
               )

      assert Enum.map(summary.added, & &1.name) == ["Vim", "Tmux"]
      assert summary.meta_set == true

      names =
        session_id
        |> library_rows("library:Eng")
        |> Enum.map(&Rho.MapAccess.get(&1, :skill_name))

      assert names == ["Vim", "Tmux"]
    end
  end

  describe "run/2 — input handling" do
    test "missing name returns :missing_name", %{org_id: org_id, session_id: session_id} do
      assert {:error, :missing_name} =
               GenerateFrameworkSkeletons.run(
                 %{description: "X"},
                 scope(org_id, session_id)
               )
    end

    test "missing description returns :missing_description", %{
      org_id: org_id,
      session_id: session_id
    } do
      assert {:error, :missing_description} =
               GenerateFrameworkSkeletons.run(
                 %{name: "Eng"},
                 scope(org_id, session_id)
               )
    end

    test "skill_count flows through to the seam input", %{
      org_id: org_id,
      session_id: session_id
    } do
      Application.put_env(:rho_frameworks, :generate_skeleton_fn, fn input, _on_partial ->
        send(self(), {:input, input})
        {:ok, %{name: "Eng", description: "X", skills: []}}
      end)

      assert {:ok, %{requested: 8}} =
               GenerateFrameworkSkeletons.run(
                 %{name: "Eng", description: "X", skill_count: 8},
                 scope(org_id, session_id)
               )

      assert_received {:input, input}
      assert input.skill_count == "8"
    end

    test "research and seeds default to '(none)' when blank", %{
      org_id: org_id,
      session_id: session_id
    } do
      Application.put_env(:rho_frameworks, :generate_skeleton_fn, fn input, _on_partial ->
        send(self(), {:input, input})
        {:ok, %{name: "Eng", description: "X", skills: []}}
      end)

      assert {:ok, _} =
               GenerateFrameworkSkeletons.run(
                 %{name: "Eng", description: "X"},
                 scope(org_id, session_id)
               )

      assert_received {:input, input}
      assert input.seeds == "(none)"
      assert input.research == "(none)"
    end
  end

  describe "run/2 — error propagation" do
    test "propagates seam errors", %{org_id: org_id, session_id: session_id} do
      Application.put_env(:rho_frameworks, :generate_skeleton_fn, fn _input, _cb ->
        {:error, :nope}
      end)

      assert {:error, :nope} =
               GenerateFrameworkSkeletons.run(
                 %{name: "Eng", description: "X"},
                 scope(org_id, session_id)
               )
    end
  end

  describe "run/2 — :gaps_only scope (extend_existing path)" do
    test "passes seed_skills and gaps to seam, writes into the supplied table_name", %{
      org_id: org_id,
      session_id: session_id
    } do
      parent = self()

      Application.put_env(:rho_frameworks, :generate_skeleton_fn, fn input, on_partial ->
        send(parent, {:seam_input, input})

        on_partial.(:skill, %{
          category: "Eng",
          cluster: "Backend",
          name: "Caching",
          description: "Cache strategy."
        })

        {:ok,
         %{
           name: input.name,
           description: input.description,
           skills: [
             %{
               category: "Eng",
               cluster: "Backend",
               name: "Caching",
               description: "Cache strategy."
             }
           ]
         }}
      end)

      input = %{
        name: "Backend Eng v2",
        description: "Extended",
        scope: :gaps_only,
        table_name: "library:Backend Eng",
        seed_skills: [
          %{skill_name: "API Design", category: "Eng", cluster: "Backend"},
          %{skill_name: "DB Modeling", category: "Eng", cluster: "Backend"}
        ],
        gaps: [
          %{skill_name: "Caching", category: "Eng", rationale: "PMs read-heavy."}
        ]
      }

      assert {:ok, summary} = GenerateFrameworkSkeletons.run(input, scope(org_id, session_id))

      assert summary.scope == :gaps_only
      assert summary.table_name == "library:Backend Eng"

      rows = library_rows(session_id, "library:Backend Eng")
      names = Enum.map(rows, &Rho.MapAccess.get(&1, :skill_name))
      assert "Caching" in names

      assert_received {:seam_input, seam_input}
      assert seam_input.existing_skills =~ "API Design"
      assert seam_input.existing_skills =~ "DB Modeling"
      assert seam_input.gaps =~ "Caching"
      assert seam_input.gaps =~ "PMs read-heavy"
    end

    test "default scope is :full and renders existing_skills/gaps as (none)", %{
      org_id: org_id,
      session_id: session_id
    } do
      parent = self()

      Application.put_env(:rho_frameworks, :generate_skeleton_fn, fn input, _on_partial ->
        send(parent, {:seam_input, input})

        {:ok,
         %{
           name: input.name,
           description: input.description,
           skills: []
         }}
      end)

      assert {:ok, summary} =
               GenerateFrameworkSkeletons.run(
                 %{name: "Eng", description: "Generic"},
                 scope(org_id, session_id)
               )

      assert summary.scope == :full
      assert summary.table_name == "library:Eng"

      assert_received {:seam_input, seam_input}
      assert seam_input.existing_skills == "(none)"
      assert seam_input.gaps == "(none)"
    end
  end
end
