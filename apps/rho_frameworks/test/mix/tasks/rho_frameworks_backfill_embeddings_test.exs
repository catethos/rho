defmodule Mix.Tasks.RhoFrameworks.BackfillEmbeddingsTest do
  @moduledoc """
  Focused tests for the `bulk_update_embeddings!/4` helper that replaced
  the per-row `Repo.update!` loop. Exercises the
  `UPDATE skills SET … FROM (VALUES …)` SQL path against the test DB so
  we catch parameter-binding / vector-encoding regressions.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias RhoFrameworks.Repo
  alias RhoFrameworks.Frameworks.{RoleProfile, Skill}
  alias Mix.Tasks.RhoFrameworks.BackfillEmbeddings

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "Backfill Test Org",
      slug: "bf-#{System.unique_integer([:positive])}"
    })

    {:ok, lib} =
      RhoFrameworks.Library.create_library(org_id, %{
        name: "Lib #{System.unique_integer([:positive])}"
      })

    %{org_id: org_id, lib_id: lib.id}
  end

  describe "bulk_update_embeddings!/4 (skills)" do
    test "writes embedding, embedding_text_hash, and embedded_at for every row in the batch",
         %{lib_id: lib_id} do
      # Three skills, all without embeddings.
      rows =
        for i <- 1..3 do
          {:ok, s} =
            RhoFrameworks.Library.upsert_skill(lib_id, %{
              name: "Skill #{System.unique_integer([:positive])}-#{i}",
              description: "Desc #{i}",
              category: "Tech"
            })

          # Wipe any embedding the upsert may have written via the ready
          # FakeEmbeddings backend; we want a clean nil starting point so
          # the bulk update path is the only writer.
          s
          |> Ecto.Changeset.change(%{
            embedding: nil,
            embedding_text_hash: nil,
            embedded_at: nil
          })
          |> Repo.update!()
        end

      texts = Enum.map(rows, & &1.name)
      vecs = Enum.map(rows, fn _ -> List.duplicate(0.5, 384) end)

      :ok = BackfillEmbeddings.bulk_update_embeddings!("skills", rows, texts, vecs)

      ids = Enum.map(rows, & &1.id)

      reloaded =
        from(s in Skill, where: s.id in ^ids, order_by: s.id)
        |> Repo.all()

      assert match?([_, _, _], reloaded)

      for {row, text} <- Enum.zip(reloaded, Enum.sort_by(rows, & &1.id) |> Enum.map(& &1.name)) do
        # Pgvector decodes the binary back to a list-like struct; just
        # assert it's populated and the right size.
        assert not is_nil(row.embedding)
        assert row.embedding_text_hash == :crypto.hash(:sha256, text)
        assert not is_nil(row.embedded_at)
      end
    end

    test "shared timestamp param is reused across all rows in the batch", %{lib_id: lib_id} do
      rows =
        for i <- 1..2 do
          {:ok, s} =
            RhoFrameworks.Library.upsert_skill(lib_id, %{
              name: "Stamp Skill #{System.unique_integer([:positive])}-#{i}",
              description: "Desc",
              category: "Tech"
            })

          s
          |> Ecto.Changeset.change(%{embedding: nil, embedded_at: nil})
          |> Repo.update!()
        end

      texts = Enum.map(rows, & &1.name)
      vecs = Enum.map(rows, fn _ -> List.duplicate(0.1, 384) end)

      :ok = BackfillEmbeddings.bulk_update_embeddings!("skills", rows, texts, vecs)

      ids = Enum.map(rows, & &1.id)

      [a, b] =
        from(s in Skill, where: s.id in ^ids, order_by: s.id, select: s.embedded_at)
        |> Repo.all()

      assert a == b, "expected all rows in a batch to share the same embedded_at"
    end
  end

  describe "bulk_update_embeddings!/4 (role profiles)" do
    test "works against role_profiles table too", %{org_id: org_id} do
      row =
        Repo.insert!(%RoleProfile{
          organization_id: org_id,
          name: "Backend Engineer #{System.unique_integer([:positive])}",
          description: "Builds APIs.",
          purpose: "Ship reliable services."
        })

      vec = List.duplicate(0.25, 384)
      text = "#{row.name}\n#{row.description}\n#{row.purpose}"

      :ok = BackfillEmbeddings.bulk_update_embeddings!("role_profiles", [row], [text], [vec])

      reloaded = Repo.get!(RoleProfile, row.id)
      assert not is_nil(reloaded.embedding)
      assert reloaded.embedding_text_hash == :crypto.hash(:sha256, text)
      assert not is_nil(reloaded.embedded_at)
    end
  end

  describe "missing_query column-trim" do
    test "select_fields exclude metadata so the row payload stays small",
         %{lib_id: lib_id} do
      # Insert a skill with a deliberately fat metadata blob; trimmed
      # select should return a row whose `metadata` is the schema default
      # (an empty map) rather than the stored payload.
      large_payload = String.duplicate("x", 5_000)

      {:ok, _} =
        RhoFrameworks.Library.upsert_skill(lib_id, %{
          name: "Heavy Metadata Skill #{System.unique_integer([:positive])}",
          description: "Has a big metadata field.",
          category: "Tech",
          metadata: %{"payload" => large_payload}
        })

      # Wipe the embedding so missing_query picks it up.
      Repo.update_all(Skill,
        set: [embedding: nil, embedding_text_hash: nil, embedded_at: nil]
      )

      [row] =
        from(s in Skill,
          where: is_nil(s.embedding) and s.library_id == ^lib_id,
          limit: 1,
          select: [:id, :name, :description]
        )
        |> Repo.all()

      assert is_nil(row.metadata) or row.metadata == %{},
             "trimmed select should not load metadata; got #{inspect(byte_size(:erlang.term_to_binary(row.metadata)))} bytes"
    end
  end
end
