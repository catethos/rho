defmodule Mix.Tasks.RhoFrameworks.BackfillEmbeddings do
  @shortdoc "Compute embeddings for skills and/or role profiles missing them"

  @moduledoc """
  Backfill `embedding`, `embedding_text_hash`, and `embedded_at` for skill
  and/or role-profile rows missing an up-to-date embedding. Idempotent —
  re-running picks up only rows still in need.

  Embeddings are computed in batches via `RhoEmbeddings.embed_many/1`
  against the configured backend (Pythonx in prod, Fake in tests). Empty
  no-op if the embeddings server is disabled or not yet ready.

  ## Targets

  | Target | Rows | Re-embed condition |
  |--------|------|-------------------|
  | `skill` (default) | `skills` | `embedding IS NULL` |
  | `role`  | `role_profiles` | `embedding IS NULL` |
  | `all`   | both | as above, skills first then roles |

  `embedding_text_hash` is populated on every backfill so future
  re-embed-on-edit logic can compare a freshly computed hash against
  the stored one. Until that's wired up, re-embedding an edited row
  means clearing the column manually (e.g.
  `UPDATE role_profiles SET embedding = NULL WHERE id = '…'`).

  ## Usage

      mix rho_frameworks.backfill_embeddings                  # --target skill (default)
      mix rho_frameworks.backfill_embeddings --target role
      mix rho_frameworks.backfill_embeddings --target all --batch 200
      mix rho_frameworks.backfill_embeddings --batch 50
  """

  use Mix.Task

  import Ecto.Query

  alias RhoFrameworks.Frameworks.{RoleProfile, Skill}
  alias RhoFrameworks.Repo

  @default_batch_size 100
  @valid_targets ~w(skill role all)

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [batch: :integer, target: :string])

    batch_size = opts[:batch] || @default_batch_size
    target = opts[:target] || "skill"

    unless target in @valid_targets do
      Mix.shell().error(
        "Invalid --target #{inspect(target)}. Valid: #{Enum.join(@valid_targets, ", ")}"
      )

      exit({:shutdown, 1})
    end

    # `app.start` loads runtime.exs (DATABASE_URL/NEON_URL) and starts
    # the supervision tree for rho_frameworks + rho_embeddings.
    Mix.Task.run("app.start")

    cond do
      not embeddings_enabled?() ->
        Mix.shell().info("RhoEmbeddings disabled — nothing to backfill.")
        :ok

      not wait_until_ready(:timer.minutes(5)) ->
        Mix.shell().info(
          "RhoEmbeddings did not become ready within 5min (model still loading or load failed); aborting backfill."
        )

        :ok

      true ->
        do_backfill(target, batch_size)
    end
  end

  defp wait_until_ready(deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_until_ready(deadline)
  end

  defp do_wait_until_ready(deadline) do
    cond do
      RhoEmbeddings.ready?() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(200)
        do_wait_until_ready(deadline)
    end
  end

  # ── target dispatch ─────────────────────────────────────────────────────

  defp do_backfill("skill", batch_size), do: backfill_target(:skill, batch_size)
  defp do_backfill("role", batch_size), do: backfill_target(:role, batch_size)

  defp do_backfill("all", batch_size) do
    backfill_target(:skill, batch_size)
    backfill_target(:role, batch_size)
  end

  defp backfill_target(target, batch_size) do
    spec = target_spec(target)
    total = Repo.aggregate(spec.missing_query.(), :count, :id)

    if total == 0 do
      Mix.shell().info("No #{spec.label} missing embeddings — nothing to do.")
    else
      Mix.shell().info(
        "Backfilling embeddings for #{total} #{spec.label} (batch size #{batch_size})..."
      )

      backfill_loop(spec, 0, total, batch_size)
    end
  end

  defp backfill_loop(spec, processed, total, _batch_size) when processed >= total do
    Mix.shell().info("Backfill complete: processed #{processed}/#{total} #{spec.label}.")
  end

  defp backfill_loop(spec, processed, total, batch_size) do
    # Pull only `id` + the columns the text builder reads. Skips the wide
    # `metadata` jsonb (~700 bytes/row for ESCO skills) and the soon-to-be
    # overwritten embedding fields. Across 14k rows that's ~10MB saved per
    # full backfill.
    rows =
      spec.missing_query.()
      |> order_by(asc: :id)
      |> limit(^batch_size)
      |> select(^spec.select_fields)
      |> Repo.all()

    case rows do
      [] ->
        Mix.shell().info("Backfill complete: processed #{processed}/#{total} #{spec.label}.")

      _ ->
        case embed_batch(rows, spec) do
          {:ok, n} ->
            new_total = processed + n

            Mix.shell().info("  Batch: embedded #{n} #{spec.label} (#{new_total}/#{total})")

            backfill_loop(spec, new_total, total, batch_size)

          {:error, reason} ->
            Mix.shell().error("Embedding batch failed (#{inspect(reason)}); aborting.")
        end
    end
  end

  defp embed_batch(rows, spec) do
    texts = Enum.map(rows, spec.text_for)

    case RhoEmbeddings.embed_many(texts) do
      {:ok, vecs} ->
        bulk_update_embeddings!(spec.table, rows, texts, vecs)
        {:ok, length(rows)}

      {:error, _} = err ->
        err
    end
  end

  # ── bulk update via UPDATE ... FROM (VALUES ...) ───────────────────────
  #
  # One SQL round-trip per batch instead of N. The original loop did a
  # synchronous `Repo.update!` per row — at ~50ms RTT to a remote Neon
  # endpoint, 200 sequential round-trips per batch dominated wall time
  # (~14s/batch observed). Single batched UPDATE drops it to ~250ms.
  #
  # Postgres parameter limit is 65,535. Each row contributes 3 params
  # (id, embedding, hash) plus 1 shared timestamp param; batch_size 200
  # = 601 params, batch_size 5,000 = 15,001 — both well under the limit.
  @doc false
  def bulk_update_embeddings!(table, rows, texts, vecs) do
    triples =
      [rows, texts, vecs]
      |> Enum.zip()
      |> Enum.map(fn {row, text, vec} ->
        {row.id, vec, :crypto.hash(:sha256, text)}
      end)

    placeholders =
      triples
      |> Enum.with_index()
      |> Enum.map_join(",\n      ", fn {_, idx} ->
        # $1 is the shared `now` param; row params start at $2.
        base = idx * 3 + 2
        "($#{base}::uuid, $#{base + 1}::vector, $#{base + 2}::bytea)"
      end)

    params =
      [DateTime.utc_now() |> DateTime.truncate(:microsecond)] ++
        Enum.flat_map(triples, fn {id, vec, hash} ->
          {:ok, id_bin} = Ecto.UUID.dump(id)
          [id_bin, vec, hash]
        end)

    sql = """
    UPDATE #{table} AS t SET
      embedding = data.embedding,
      embedding_text_hash = data.hash,
      embedded_at = $1,
      updated_at = $1
    FROM (VALUES
      #{placeholders}
    ) AS data(id, embedding, hash)
    WHERE t.id = data.id
    """

    Ecto.Adapters.SQL.query!(Repo, sql, params)
    :ok
  end

  # ── per-target spec ─────────────────────────────────────────────────────
  #
  # Returns:
  #   * label         — for log lines
  #   * table         — DB table name for the bulk UPDATE
  #   * missing_query — 0-arity fn returning a queryable filtered to
  #                     rows still needing an embedding
  #   * select_fields — Ecto select list trimming the row to text-source +
  #                     id columns; saves bandwidth on wide jsonb
  #   * text_for      — 1-arity fn computing the embed text from a row

  defp target_spec(:skill) do
    %{
      label: "skills",
      table: "skills",
      missing_query: fn -> from(s in Skill, where: is_nil(s.embedding)) end,
      select_fields: [:id, :name, :description],
      text_for: &skill_text/1
    }
  end

  defp target_spec(:role) do
    %{
      label: "role profiles",
      table: "role_profiles",
      missing_query: fn -> from(rp in RoleProfile, where: is_nil(rp.embedding)) end,
      select_fields: [:id, :name, :description, :purpose],
      text_for: &role_text/1
    }
  end

  defp skill_text(%Skill{name: name, description: desc}) do
    "#{name}\n#{desc || ""}"
  end

  defp role_text(%RoleProfile{name: name, description: desc, purpose: purpose}) do
    [name, desc, purpose]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n")
  end

  defp embeddings_enabled? do
    Application.get_env(:rho_embeddings, :enabled, true)
  end
end
