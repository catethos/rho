defmodule RhoFrameworks.Library.DedupTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.Accounts.Organization
  alias RhoFrameworks.Library
  alias RhoFrameworks.Library.Dedup
  alias RhoFrameworks.Repo

  setup do
    org =
      Repo.insert!(%Organization{
        name: "Dedup Org",
        slug: "dedup-org-#{System.unique_integer([:positive])}"
      })

    {:ok, library} = Library.create_library(org.id, %{name: "Dedup"})

    %{org: org, library: library}
  end

  test "find_duplicates/2 detects likely duplicates and facade delegates", %{library: library} do
    {:ok, first} = Library.upsert_skill(library.id, %{name: "SQL Programming", category: "Tech"})
    {:ok, second} = Library.upsert_skill(library.id, %{name: "SQL Querying", category: "Tech"})

    direct = Dedup.find_duplicates(library.id)
    facade = Library.find_duplicates(library.id)

    assert direct == facade

    assert Enum.any?(direct, fn pair ->
             MapSet.equal?(
               MapSet.new([pair.skill_a.id, pair.skill_b.id]),
               MapSet.new([first.id, second.id])
             )
           end)
  end

  test "dismiss_duplicate/3 suppresses future duplicate candidates", %{library: library} do
    {:ok, first} = Library.upsert_skill(library.id, %{name: "SQL Programming", category: "Tech"})
    {:ok, second} = Library.upsert_skill(library.id, %{name: "SQL Querying", category: "Tech"})

    assert Dedup.find_duplicates(library.id) != []

    assert {:ok, _dismissal} = Dedup.dismiss_duplicate(library.id, second.id, first.id)
    assert Dedup.find_duplicates(library.id) == []
  end

  test "consolidation_report/1 groups duplicate, draft, and orphan signals", %{library: library} do
    {:ok, _first} = Library.upsert_skill(library.id, %{name: "SQL Programming", category: "Tech"})
    {:ok, _second} = Library.upsert_skill(library.id, %{name: "SQL Querying", category: "Tech"})

    report = Dedup.consolidation_report(library.id)

    assert report.total_skills == 2
    assert report.duplicate_pairs != []

    assert report.drafts |> Enum.map(& &1.name) |> Enum.sort() == [
             "SQL Programming",
             "SQL Querying"
           ]

    assert report.orphans |> Enum.map(& &1.name) |> Enum.sort() == [
             "SQL Programming",
             "SQL Querying"
           ]
  end
end
