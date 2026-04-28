defmodule RhoFrameworks.UseCases.SuggestSkillsTest do
  @moduledoc """
  Tests for the `Suggest more skills` UseCase. The LLM call is replaced
  via the `:suggest_fn` Application env so these run without hitting
  BAML / OpenRouter.
  """

  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{DataTableSchemas, Scope}
  alias RhoFrameworks.UseCases.SuggestSkills

  setup do
    session_id = "sess-suggest-#{System.unique_integer([:positive])}"
    {:ok, _pid} = DataTable.ensure_started(session_id)

    :ok =
      DataTable.ensure_table(session_id, "library", DataTableSchemas.library_schema())

    on_exit(fn ->
      Application.delete_env(:rho_frameworks, :suggest_fn)
      DataTable.stop(session_id)
    end)

    scope = %Scope{
      organization_id: "org-test",
      session_id: session_id,
      user_id: "user-test"
    }

    %{scope: scope, session_id: session_id}
  end

  defp put_seam(skills) do
    Application.put_env(:rho_frameworks, :suggest_fn, fn _existing, _intake, _n, on_partial ->
      Enum.each(skills, on_partial)
      {:ok, skills}
    end)
  end

  defp library_rows(session_id) do
    DataTable.get_rows(session_id, table: "library")
  end

  describe "describe/0" do
    test "advertises a cheap, one-shot UseCase" do
      assert %{id: :suggest_skills, cost_hint: :cheap} = SuggestSkills.describe()
    end
  end

  describe "run/2" do
    test "streams partials into the library via Workbench in order", %{
      scope: scope,
      session_id: session_id
    } do
      put_seam([
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

      assert {:ok, %{requested: 5, returned: 2}} = SuggestSkills.run(%{n: 5}, scope)

      rows = library_rows(session_id)
      names = Enum.map(rows, &(&1[:skill_name] || &1["skill_name"]))
      assert names == ["Vim", "Tmux"]

      sources = Enum.map(rows, &(&1[:_source] || &1["_source"]))
      assert Enum.all?(sources, &(&1 == "agent"))
    end

    test "duplicate skill_name partials are skipped silently", %{
      scope: scope,
      session_id: session_id
    } do
      put_seam([
        %{category: "Eng", cluster: "Tooling", name: "Vim", description: "Editor."},
        # BAML may re-emit the same partial as the array grows; treat as benign.
        %{category: "Eng", cluster: "Tooling", name: "Vim", description: "Editor."},
        %{category: "Eng", cluster: "Tooling", name: "Tmux", description: "Multiplexer."}
      ])

      assert {:ok, %{returned: 3}} = SuggestSkills.run(%{n: 5}, scope)

      names =
        session_id
        |> library_rows()
        |> Enum.map(&(&1[:skill_name] || &1["skill_name"]))

      assert names == ["Vim", "Tmux"]
    end

    test "skips partials missing required fields without crashing", %{
      scope: scope,
      session_id: session_id
    } do
      put_seam([
        # Missing description — to_row returns :skip, no add_skill call.
        %{category: "Eng", cluster: "Tooling", name: "Vim", description: ""},
        %{
          category: "Eng",
          cluster: "Tooling",
          name: "Tmux",
          description: "Multiplexer."
        }
      ])

      assert {:ok, _} = SuggestSkills.run(%{n: 5}, scope)

      names =
        session_id
        |> library_rows()
        |> Enum.map(&(&1[:skill_name] || &1["skill_name"]))

      assert names == ["Tmux"]
    end

    test "clamps n at 10 and defaults missing n to 5", %{scope: scope} do
      Application.put_env(:rho_frameworks, :suggest_fn, fn _existing, _intake, n, _on_partial ->
        send(self(), {:n_passed, n})
        {:ok, []}
      end)

      assert {:ok, %{requested: 10}} = SuggestSkills.run(%{n: 50}, scope)
      assert_received {:n_passed, 10}

      assert {:ok, %{requested: 5}} = SuggestSkills.run(%{}, scope)
      assert_received {:n_passed, 5}
    end

    test "returns the fully-formed added skills so the LV can flash names", %{scope: scope} do
      put_seam([
        %{category: "Eng", cluster: "Tooling", name: "Vim", description: "Editor."},
        # Missing description — filtered out of :added.
        %{category: "Eng", cluster: "Tooling", name: "BadSkill", description: ""},
        %{category: "Eng", cluster: "Languages", name: "Elixir", description: "FP lang."}
      ])

      assert {:ok, %{added: added}} = SuggestSkills.run(%{n: 5}, scope)

      assert Enum.map(added, & &1.name) == ["Vim", "Elixir"]
      assert Enum.map(added, & &1.cluster) == ["Tooling", "Languages"]
      assert Enum.map(added, & &1.category) == ["Eng", "Eng"]
    end

    test "propagates seam errors", %{scope: scope} do
      Application.put_env(:rho_frameworks, :suggest_fn, fn _e, _i, _n, _cb ->
        {:error, :nope}
      end)

      assert {:error, :nope} = SuggestSkills.run(%{n: 3}, scope)
    end

    test "writes into a custom :table when the active library is library:<name>", %{
      scope: scope,
      session_id: session_id
    } do
      :ok =
        DataTable.ensure_table(session_id, "library:Eng", DataTableSchemas.library_schema())

      put_seam([
        %{category: "Eng", cluster: "Tooling", name: "Vim", description: "Editor."}
      ])

      assert {:ok, _} = SuggestSkills.run(%{n: 1, table: "library:Eng"}, scope)

      rows = DataTable.get_rows(session_id, table: "library:Eng")
      assert [row] = rows
      assert (row[:skill_name] || row["skill_name"]) == "Vim"
    end
  end
end
