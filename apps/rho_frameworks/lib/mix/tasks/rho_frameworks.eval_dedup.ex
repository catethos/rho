defmodule Mix.Tasks.RhoFrameworks.EvalDedup do
  @shortdoc "Sweep cosine thresholds against a real library and emit a CSV"

  @moduledoc """
  Empirical threshold tuning for `find_semantic_duplicates_via_llm/2`.

  Runs the dedup pipeline at a sweep of cosine-distance thresholds and
  emits a CSV summary so the production `@semantic_distance_threshold`
  can be picked from data instead of a guess.

  ## Pipeline per threshold

      candidates = (cosine_pairs(library, t) ++ jaro_fallback(skills))
                   |> dedup_by_id()
      confirmed  = candidates ∩ llm_confirmed_set

  The LLM verification runs **once** at the loosest threshold in the
  sweep — every pair confirmed there stays confirmed at any tighter
  threshold (LLM verdict is threshold-independent). This keeps eval
  cost flat regardless of sweep width.

  ## Usage

      # Default — FSFM library, thresholds [0.30..0.55] step 0.05
      mix rho_frameworks.eval_dedup

      # Custom library + thresholds
      mix rho_frameworks.eval_dedup --library-name "My Library" \\
        --thresholds 0.20,0.30,0.40,0.50,0.60

      # Skip LLM (cheap dry-run, just candidate counts)
      mix rho_frameworks.eval_dedup --no-llm

  ## Output

  CSV with one row per threshold:

      threshold,cosine_candidates,fallback_candidates,total_unique,
      llm_chunks,confirmed_dupes,est_tokens,elapsed_ms

  - `cosine_candidates`: pairs returned by the SQL `<=>` filter at this
    threshold.
  - `fallback_candidates`: pairs from the jaro fallback (skills missing
    embeddings × full library) — same at every threshold.
  - `total_unique`: combined and deduped by skill-id pair.
  - `llm_chunks`: chunks the production code would emit at this
    threshold (`ceil(total_unique / 40)`). Used for cost projection;
    the actual eval only runs LLM once on the loosest threshold.
  - `confirmed_dupes`: candidates at this threshold that the LLM
    confirmed as true duplicates.
  - `est_tokens`: rough token-usage estimate (chunks × 2500). The
    SemanticDuplicates prompt is ~300 tokens + 40 pairs × ~50 tokens =
    ~2300 input + ~100 output ≈ 2400 per chunk.

  Reads only — does not mutate any rows.
  """

  use Mix.Task

  import Ecto.Query

  alias RhoFrameworks.Frameworks.{Library, Skill}
  alias RhoFrameworks.Repo

  @default_thresholds [0.30, 0.35, 0.40, 0.45, 0.50, 0.55]
  @default_output "tmp/dedup_eval.csv"
  @default_library_name "Future Skills Framework - Malaysian Financial Sector"
  @jaro_fallback_threshold 0.6
  @chunk_size 40
  @chunk_concurrency 16
  @chunk_timeout_ms 60_000
  @est_tokens_per_chunk 2500

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          library_id: :string,
          library_name: :string,
          thresholds: :string,
          output: :string,
          no_llm: :boolean
        ]
      )

    # `app.start` loads runtime.exs (DATABASE_URL/NEON_URL) and starts
    # the supervision tree for rho_frameworks.
    Mix.Task.run("app.start")

    library = resolve_library!(opts)
    thresholds = parse_thresholds(opts[:thresholds])
    output = opts[:output] || @default_output
    skip_llm? = opts[:no_llm] || false

    skills = Repo.all(from(s in Skill, where: s.library_id == ^library.id))

    with_embedding = Enum.count(skills, fn s -> not is_nil(s.embedding) end)
    without_embedding = length(skills) - with_embedding

    Mix.shell().info("=== eval_dedup library=#{library.name} (#{library.id})")

    Mix.shell().info(
      "    skills total=#{length(skills)} with_embedding=#{with_embedding} " <>
        "without_embedding=#{without_embedding}"
    )

    Mix.shell().info("    thresholds=#{inspect(thresholds)}")
    Mix.shell().info("")

    fallback_pairs = candidate_pairs_via_jaro_fallback(skills, @jaro_fallback_threshold)
    sweep_max = Enum.max(thresholds)

    confirmed_set =
      if skip_llm? do
        Mix.shell().info("    --no-llm: skipping LLM verification")
        MapSet.new()
      else
        run_llm_pass(library.id, sweep_max, fallback_pairs)
      end

    Mix.shell().info("")
    Mix.shell().info("    confirmed pair-ids: #{MapSet.size(confirmed_set)}")
    Mix.shell().info("")

    rows =
      Enum.map(thresholds, fn t ->
        evaluate(t, library.id, fallback_pairs, confirmed_set)
      end)

    File.mkdir_p!(Path.dirname(output))
    write_csv(output, rows)
    print_summary(rows)

    Mix.shell().info("")
    Mix.shell().info("Wrote #{output}")
  end

  # --- Pipeline ---

  defp run_llm_pass(library_id, sweep_max, fallback_pairs) do
    cosine_pairs = candidate_pairs_via_embedding(library_id, sweep_max)
    all_pairs = dedup_pairs(cosine_pairs ++ fallback_pairs)

    chunk_count = chunk_count_for(length(all_pairs))

    Mix.shell().info(
      "    LLM verification at sweep_max=#{sweep_max} — " <>
        "#{length(all_pairs)} candidates → #{chunk_count} chunks"
    )

    if all_pairs == [] do
      MapSet.new()
    else
      all_pairs
      |> build_focal_chunks(@chunk_size)
      |> Task.async_stream(&verify_focal_chunk/1,
        max_concurrency: @chunk_concurrency,
        timeout: @chunk_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, pair_ids} when is_list(pair_ids) ->
          pair_ids

        {:ok, _} ->
          []

        {:exit, reason} ->
          Mix.shell().error("LLM chunk crashed: #{inspect(reason)}")
          []
      end)
      |> MapSet.new()
    end
  end

  defp evaluate(threshold, library_id, fallback_pairs, confirmed_set) do
    started = System.monotonic_time(:millisecond)

    cosine_pairs = candidate_pairs_via_embedding(library_id, threshold)
    all_pairs = dedup_pairs(cosine_pairs ++ fallback_pairs)

    confirmed =
      Enum.count(all_pairs, fn {a, b} ->
        MapSet.member?(confirmed_set, pair_key(a, b))
      end)

    chunks = chunk_count_for(length(all_pairs))

    %{
      threshold: threshold,
      cosine_candidates: length(cosine_pairs),
      fallback_candidates: length(fallback_pairs),
      total_unique: length(all_pairs),
      llm_chunks: chunks,
      confirmed_dupes: confirmed,
      est_tokens: chunks * @est_tokens_per_chunk,
      elapsed_ms: System.monotonic_time(:millisecond) - started
    }
  end

  defp candidate_pairs_via_embedding(library_id, threshold) do
    # Pairwise self-join can't use the HNSW index (HNSW is KNN-only), so
    # this is a sequential cosine scan over n*(n-1)/2 pairs. Bump the
    # checkout/query timeout to 2min so Neon's round-trip latency
    # doesn't blow past Postgrex's default 15s.
    from(s1 in Skill,
      join: s2 in Skill,
      on: s2.library_id == s1.library_id and s2.id > s1.id,
      where: s1.library_id == ^library_id,
      where: not is_nil(s1.embedding) and not is_nil(s2.embedding),
      where: fragment("(? <=> ?) < ?", s1.embedding, s2.embedding, ^threshold),
      select: {s1, s2}
    )
    |> Repo.all(timeout: :timer.minutes(2))
  end

  defp candidate_pairs_via_jaro_fallback(skills, threshold) do
    {without, _with} = Enum.split_with(skills, fn s -> is_nil(s.embedding) end)

    case without do
      [] ->
        []

      _ ->
        for a <- without,
            b <- skills,
            a.id != b.id,
            String.jaro_distance(String.downcase(a.name), String.downcase(b.name)) >= threshold do
          if a.id < b.id, do: {a, b}, else: {b, a}
        end
        |> Enum.uniq_by(fn {a, b} -> {a.id, b.id} end)
    end
  end

  # Group pairs by focal skill (smaller-id side of each pair) so each LLM
  # call sees one focal + N candidates instead of N disjoint pairs. Same
  # shape as the production pipeline in RhoFrameworks.Library.
  defp build_focal_chunks(pairs, max_candidates) do
    pairs
    |> Enum.reduce(%{}, fn {a, b}, acc ->
      {focal, neighbor} = if a.id < b.id, do: {a, b}, else: {b, a}

      Map.update(acc, focal.id, {focal, [neighbor]}, fn {f, ns} ->
        {f, [neighbor | ns]}
      end)
    end)
    |> Map.values()
    |> Enum.flat_map(fn {focal, neighbors} ->
      neighbors
      |> Enum.chunk_every(max_candidates)
      |> Enum.map(fn chunk -> {focal, chunk} end)
    end)
  end

  defp verify_focal_chunk({focal, candidates}) do
    indexed = Enum.with_index(candidates)

    candidates_text =
      Enum.map_join(indexed, "\n", fn {c, idx} ->
        "[#{idx}] #{format_skill(c)}"
      end)

    case RhoFrameworks.LLM.SemanticDuplicates.call(%{
           focal: format_skill(focal),
           candidates: candidates_text
         }) do
      {:ok, %{duplicate_indices: indices}} ->
        confirmed = MapSet.new(indices)

        for {neighbor, idx} <- indexed,
            MapSet.member?(confirmed, idx),
            do: pair_key(focal, neighbor)

      {:error, reason} ->
        Mix.shell().error("LLM call failed: #{inspect(reason)}")
        []
    end
  end

  defp format_skill(s) do
    desc = if s.description && s.description != "", do: " — #{s.description}", else: ""
    "#{s.name} (#{s.category})#{desc}"
  end

  defp dedup_pairs(pairs), do: Enum.uniq_by(pairs, fn {a, b} -> {a.id, b.id} end)

  defp pair_key(a, b) do
    if a.id < b.id, do: {a.id, b.id}, else: {b.id, a.id}
  end

  defp chunk_count_for(0), do: 0
  defp chunk_count_for(n), do: ceil(n / @chunk_size)

  # --- Resolution / parsing ---

  defp resolve_library!(opts) do
    cond do
      id = opts[:library_id] ->
        Repo.get!(Library, id)

      name = opts[:library_name] ->
        case Repo.one(from(l in Library, where: l.name == ^name, limit: 1)) do
          nil -> Mix.raise("library not found by name: #{name}")
          lib -> lib
        end

      true ->
        case Repo.one(from(l in Library, where: l.name == ^@default_library_name, limit: 1)) do
          nil ->
            Mix.raise(
              "default library #{inspect(@default_library_name)} not found — " <>
                "pass --library-id or --library-name"
            )

          lib ->
            lib
        end
    end
  end

  defp parse_thresholds(nil), do: @default_thresholds

  defp parse_thresholds(s) when is_binary(s) do
    s
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn token ->
      case Float.parse(token) do
        {f, ""} -> f
        _ -> Mix.raise("invalid threshold: #{inspect(token)} (must be a float like 0.45)")
      end
    end)
  end

  # --- Output ---

  defp write_csv(path, rows) do
    header =
      "threshold,cosine_candidates,fallback_candidates,total_unique," <>
        "llm_chunks,confirmed_dupes,est_tokens,elapsed_ms\n"

    body = Enum.map_join(rows, "\n", &row_to_csv/1) <> "\n"

    File.write!(path, header <> body)
  end

  defp row_to_csv(r) do
    "#{format_threshold(r.threshold)},#{r.cosine_candidates}," <>
      "#{r.fallback_candidates},#{r.total_unique},#{r.llm_chunks}," <>
      "#{r.confirmed_dupes},#{r.est_tokens},#{r.elapsed_ms}"
  end

  defp format_threshold(t), do: :erlang.float_to_binary(t, decimals: 2)

  defp print_summary(rows) do
    Mix.shell().info(
      "thr   | cosine | fallback | total | chunks | confirmed | est_tokens | elapsed_ms"
    )

    Mix.shell().info(String.duplicate("-", 80))

    Enum.each(rows, fn r ->
      Mix.shell().info(
        "#{format_threshold(r.threshold)}  | " <>
          pad(r.cosine_candidates, 6) <>
          " | " <>
          pad(r.fallback_candidates, 8) <>
          " | " <>
          pad(r.total_unique, 5) <>
          " | " <>
          pad(r.llm_chunks, 6) <>
          " | " <>
          pad(r.confirmed_dupes, 9) <>
          " | " <>
          pad(r.est_tokens, 10) <>
          " | " <>
          pad(r.elapsed_ms, 10)
      )
    end)
  end

  defp pad(v, n), do: v |> to_string() |> String.pad_leading(n)
end
