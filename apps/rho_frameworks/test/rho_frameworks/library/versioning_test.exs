defmodule RhoFrameworks.Library.VersioningTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.Accounts.Organization
  alias RhoFrameworks.Frameworks.{Library, Skill}
  alias RhoFrameworks.Library.Versioning
  alias RhoFrameworks.Repo

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%Organization{
      id: org_id,
      name: "Versioning Org",
      slug: "versioning-org-#{System.unique_integer([:positive])}"
    })

    %{org_id: org_id}
  end

  test "next_version_tag/2 increments within the current year", %{org_id: org_id} do
    year = Date.utc_today().year
    insert_library!(org_id, name: "Core", version: "#{year}.1", published_at: now())
    insert_library!(org_id, name: "Core", version: "#{year}.2", published_at: now())

    assert Versioning.next_version_tag(org_id, "Core") == "#{year}.3"
    assert RhoFrameworks.Library.next_version_tag(org_id, "Core") == "#{year}.3"
  end

  test "publish_version/4 freezes drafts and rejects duplicate versions", %{org_id: org_id} do
    draft = insert_library!(org_id, name: "Core")
    _existing = insert_library!(org_id, name: "Core", version: "2026.1", published_at: now())

    assert {:error, :version_exists, _} = Versioning.publish_version(org_id, draft.id, "2026.1")

    assert {:ok, published} =
             Versioning.publish_version(org_id, draft.id, "2026.2", notes: "Release notes")

    assert published.immutable
    assert published.version == "2026.2"
    assert published.published_at
    assert published.metadata["publish_notes"] == "Release notes"

    assert {:error, :already_published, _} =
             Versioning.publish_version(org_id, draft.id, "2026.3")
  end

  test "set_default_version/2 swaps the default published version", %{org_id: org_id} do
    current =
      insert_library!(org_id,
        name: "Core",
        version: "2026.1",
        published_at: now(),
        immutable: true,
        is_default: true
      )

    next =
      insert_library!(org_id,
        name: "Core",
        version: "2026.2",
        published_at: now(),
        immutable: true
      )

    assert {:ok, default} = Versioning.set_default_version(org_id, next.id)
    assert default.id == next.id
    assert Repo.get!(Library, next.id).is_default
    refute Repo.get!(Library, current.id).is_default

    draft = insert_library!(org_id, name: "Core")
    assert {:error, :not_published, _} = Versioning.set_default_version(org_id, draft.id)
  end

  test "diff_versions/4 reports added, removed, and modified skills", %{org_id: org_id} do
    old = insert_library!(org_id, name: "Core", version: "2026.1", published_at: now())
    new = insert_library!(org_id, name: "Core", version: "2026.2", published_at: now())

    insert_skill!(old.id, name: "SQL", description: "Old")
    insert_skill!(old.id, name: "Removed")
    insert_skill!(new.id, name: "SQL", description: "New")
    insert_skill!(new.id, name: "Added")

    assert {:ok, diff} = Versioning.diff_versions(org_id, "Core", "2026.1", "2026.2")

    assert diff.added == ["Added"]
    assert diff.removed == ["Removed"]
    assert diff.modified == ["SQL"]
    assert diff.unchanged_count == 0
  end

  defp insert_library!(org_id, attrs) do
    attrs = Map.new(attrs)

    Repo.insert!(%Library{
      name: Map.fetch!(attrs, :name),
      organization_id: org_id,
      type: Map.get(attrs, :type, "skill"),
      immutable: Map.get(attrs, :immutable, false),
      is_default: Map.get(attrs, :is_default, false),
      visibility: Map.get(attrs, :visibility, "private"),
      version: Map.get(attrs, :version),
      published_at: Map.get(attrs, :published_at),
      metadata: Map.get(attrs, :metadata, %{})
    })
  end

  defp insert_skill!(library_id, attrs) do
    attrs = Map.new(attrs)
    name = Map.fetch!(attrs, :name)

    Repo.insert!(%Skill{
      library_id: library_id,
      name: name,
      slug: Skill.slugify(name),
      category: Map.get(attrs, :category, ""),
      status: Map.get(attrs, :status, "published"),
      description: Map.get(attrs, :description, ""),
      proficiency_levels: Map.get(attrs, :proficiency_levels, [])
    })
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
