defmodule RhoFrameworks.WorkbenchResearchArchiveTest do
  @moduledoc """
  Coverage for the research-notes archive that runs as part of
  `Workbench.save_framework/3`. Pinned rows in the session's
  `research_notes` named table are persisted to the `research_notes`
  Ecto table FK'd to the saved library; unpinned rows are discarded.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{DataTableSchemas, Repo, Scope, Workbench}
  alias RhoFrameworks.Frameworks.ResearchNote
  alias RhoFrameworks.Library.Editor

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "Workbench Research Test Org",
      slug: "wb-research-#{System.unique_integer([:positive])}"
    })

    {:ok, lib} =
      RhoFrameworks.Library.create_library(org_id, %{name: "ResearchTest Lib"})

    session_id = "sess-wb-research-#{System.unique_integer([:positive])}"
    on_exit(fn -> DataTable.stop(session_id) end)

    scope = %Scope{
      organization_id: org_id,
      session_id: session_id,
      source: :flow
    }

    DataTable.ensure_started(session_id)

    DataTable.ensure_table(
      session_id,
      Editor.table_name(lib.name),
      DataTableSchemas.library_schema()
    )

    # save_framework refuses to save an empty library — seed one row so
    # the path under test reaches the research-notes archive.
    DataTable.add_rows(
      session_id,
      [
        %{
          category: "Tech",
          cluster: "Backend",
          skill_name: "Test Skill",
          skill_description: "A skill"
        }
      ],
      table: Editor.table_name(lib.name)
    )

    DataTable.ensure_table(
      session_id,
      "research_notes",
      DataTableSchemas.research_notes_schema()
    )

    %{org_id: org_id, session_id: session_id, scope: scope, library: lib}
  end

  describe "save_framework/3 archive of pinned research" do
    test "persists pinned rows and discards unpinned", %{
      session_id: sid,
      scope: scope,
      library: lib
    } do
      {:ok, _} =
        DataTable.add_rows(
          sid,
          [
            %{source: "https://example.com/1", fact: "Pinned fact A", tag: "trend", pinned: true},
            %{source: "https://example.com/2", fact: "Pinned fact B", tag: nil, pinned: true},
            %{source: "https://example.com/3", fact: "Unpinned fact", tag: "skill", pinned: false}
          ],
          table: "research_notes"
        )

      assert {:ok, summary} = Workbench.save_framework(scope, lib.id)
      assert summary.research_notes_saved == 2
      assert summary.library.id == lib.id

      notes =
        Repo.all(from(n in ResearchNote, where: n.library_id == ^lib.id, order_by: n.fact))

      assert length(notes) == 2
      facts = Enum.map(notes, & &1.fact)
      assert "Pinned fact A" in facts
      assert "Pinned fact B" in facts
      refute "Unpinned fact" in facts

      a = Enum.find(notes, &(&1.fact == "Pinned fact A"))
      assert a.tag == "trend"
      assert a.source == "https://example.com/1"
      assert a.inserted_by == "agent"
    end

    test "user-sourced notes are stamped inserted_by: 'user'", %{
      session_id: sid,
      scope: scope,
      library: lib
    } do
      {:ok, _} =
        DataTable.add_rows(
          sid,
          [%{source: "user", fact: "Hand-written", tag: nil, pinned: true}],
          table: "research_notes"
        )

      {:ok, %{research_notes_saved: 1}} = Workbench.save_framework(scope, lib.id)

      [note] = Repo.all(from(n in ResearchNote, where: n.library_id == ^lib.id))
      assert note.inserted_by == "user"
    end

    test "returns research_notes_saved: 0 when no panel was used", %{scope: scope, library: lib} do
      assert {:ok, %{research_notes_saved: 0}} = Workbench.save_framework(scope, lib.id)
    end

    test "skips archive when archive_research: false", %{
      session_id: sid,
      scope: scope,
      library: lib
    } do
      {:ok, _} =
        DataTable.add_rows(
          sid,
          [%{source: "user", fact: "Should not persist", pinned: true}],
          table: "research_notes"
        )

      {:ok, %{research_notes_saved: 0}} =
        Workbench.save_framework(scope, lib.id, archive_research: false)

      assert Repo.all(from(n in ResearchNote, where: n.library_id == ^lib.id)) == []
    end

    test "library deletion cascades to research notes", %{
      session_id: sid,
      scope: scope,
      library: lib
    } do
      {:ok, _} =
        DataTable.add_rows(
          sid,
          [%{source: "https://x", fact: "F", pinned: true}],
          table: "research_notes"
        )

      {:ok, %{research_notes_saved: 1}} = Workbench.save_framework(scope, lib.id)

      Repo.delete!(lib)

      assert Repo.all(from(n in ResearchNote, where: n.library_id == ^lib.id)) == []
    end
  end

  describe "ResearchNote.changeset" do
    test "rejects missing required fields", %{library: lib} do
      cs = ResearchNote.changeset(%ResearchNote{}, %{library_id: lib.id})
      refute cs.valid?
      errors = Keyword.keys(cs.errors)
      assert :source in errors
      assert :fact in errors
    end

    test "rejects unknown inserted_by values", %{library: lib} do
      cs =
        ResearchNote.changeset(%ResearchNote{}, %{
          library_id: lib.id,
          source: "x",
          fact: "y",
          inserted_by: "robot"
        })

      refute cs.valid?
      assert {:inserted_by, _} = List.keyfind(cs.errors, :inserted_by, 0)
    end
  end
end
