# Skill Embedding Dedup Plan

## Goal

Replace the jaro-distance pre-filter in `find_semantic_duplicates_via_llm/1`
with a cosine-similarity pre-filter on local sentence embeddings. Enables
cross-name semantic dedup ("数据分析" ↔ "Data Analysis", "Verbal
Communication" ↔ "Active Listening") that surface-form similarity cannot
catch.

This work bundles four changes that have value beyond dedup:

- **Migrate `rho_frameworks` from SQLite to Postgres + pgvector.** Neon as
  the production target. Rationale: `rho_frameworks` owns production-shape
  domain data (frameworks, libraries, skills, role profiles) that will be
  read/written concurrently by Node.js host calls into Elixir agents.
  Postgres is the no-regret OLTP store; pgvector gives indexed KNN for
  free; switching now beats migrating later under deadline pressure.
- Extract `rho_python` — owns the pythonx/erlang_python runtime lifecycle.
  Currently lives in `rho_stdlib` as accidental coupling.
- Extract `rho_embeddings` — local sentence-embedding service via
  `fastembed`. Foundation for dedup, future skill search, future
  RLM-style context retrieval (see "Future direction").
- Replace the cosine pre-filter inside the dedup path.

## Current state (post jaro/chunk patch)

- `apps/rho_frameworks/lib/rho_frameworks/library.ex` — two-stage funnel:
  jaro pre-filter (≥0.6 on lowercased names), then chunked
  `Task.async_stream` LLM verification.
- `apps/rho_frameworks/lib/rho_frameworks/llm/semantic_duplicates.ex` —
  BAML function
  `(candidate_pairs: string) -> {duplicate_indices: int[]}`.
- Pythonx + erlang_python init lives in
  `apps/rho_stdlib/lib/rho/stdlib/application.ex`.
- `apps/rho_frameworks/mix.exs` uses `ecto_sqlite3`. Repo configured
  against a local `.db` file.

## Decisions captured from spikes

- **Embedding model:**
  `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` via
  `fastembed`. 384-dim, ~210 MB quantized ONNX, Apache-2.0, ~50
  languages including en/zh/es/fr/de/ja. Trained on paraphrase pairs —
  directly aligned with dedup intent.
- **Python runtime:** pythonx (NIF), not erlang_python. Both are NIFs
  and both use dirty schedulers; pythonx fits this codebase's
  library-Python pattern (declarative `uv_init`, existing
  `AgentConfig.python_deps/0`), while erlang_python is reserved for
  stateful agent-loop Python.
- **Embedding spike numbers (Apple Silicon CPU):**
  - Per-string in batch: ~1.5 ms (any N from 10 to 1000).
  - Embed N=1000: ~1.5 s. Full dedup pass (embed + 500×500 cosine):
    ~780 ms.
  - Pythonx wrapper overhead: 0–3 ms (essentially free).
  - Cold load: ~2.5 s warm cache, ~64 s first-time download.
  - vs OpenAI `text-embedding-3-small`: local is 2.5–75× faster
    depending on batch size; cost is $0 vs ~$0.0001/1000 skills (both
    operationally negligible).
- **Quality tradeoff acknowledged:** OpenAI embeddings cluster
  cross-lingual paraphrases more tightly than MiniLM-multi. Acceptable
  for v1; revisit if dedup eval shows real cross-lingual misses.
- **Storage:** Postgres + pgvector. Hosted on Neon for staging/prod
  (free tier covers early stages; embedded-replica-style branching for
  preview environments). Local dev uses either local Postgres
  (Postgres.app / Docker) or a Neon dev branch. SQLite/libSQL/LanceDB
  evaluated and rejected — see "Storage rationale" below.

## Storage rationale

| Option | Why considered | Why rejected |
|---|---|---|
| SQLite (status quo) | Zero-friction local dev | Manual BLOB encoding for vectors; no indexed KNN; serializes writes |
| sqlite-vec extension | Keeps ecto_sqlite3 | Doesn't help all-pairs dedup; helps future search but ecosystem is thinner |
| libSQL embedded / Turso | Native vectors; SQLite-compatible | One-maintainer Ecto adapter (`ecto_libsql` 0.9); less mature than pgvector at production scale |
| LanceDB + DuckDB | Best-in-class vector + analytics | Wrong workload shape (OLTP-dominant); no mature Elixir Ecto adapter for either |
| **Postgres + pgvector** | Mature ecosystem, real concurrency, production-grade | Needs a server (Docker locally or Neon) — accepted cost |

**Rationale recap:** `rho_frameworks` is production-shape (multiple
Node.js callers, real domain data, durability matters). Postgres is the
no-regret OLTP store; pgvector is the de facto vector standard with
mature Elixir bindings; Neon removes the ops burden and gives free
branching for previews. Migration cost is bounded now, much higher
later.

## App layout

| App | Owns | Existing/New |
|---|---|---|
| `rho_python` | Pythonx + erlang_python init/lifecycle, dep aggregation, readiness signal | New |
| `rho_stdlib` | `:python` plugin, `:py_agent` plugin (consumers of `rho_python`) | Existing — refactored |
| `rho_embeddings` | `RhoEmbeddings.Server` (model + embed/cosine API) | New |
| `rho_frameworks` | `library.ex` dedup wiring, schema fields, backfill task. Migrated to Postgres + pgvector. | Existing — extended + DB migrated |

Dependency direction: `rho_embeddings` → `rho_python`; `rho_stdlib` →
`rho_python`; `rho_frameworks` → `rho_embeddings`. No app depends on
`rho_stdlib` for the Python runtime.

## Implementation

### 0. Migrate `rho_frameworks` to Postgres + pgvector

Independently shippable refactor — same schema, same behavior, different
adapter. Do this first so subsequent steps target the destination DB.

`apps/rho_frameworks/mix.exs`:

```elixir
# Replace
{:ecto_sqlite3, "~> 0.x"}
# With
{:postgrex, "~> 0.21"},
{:pgvector, "~> 0.4"}
```

Repo config (`config/config.exs` and `config/runtime.exs`):

```elixir
config :rho_frameworks, RhoFrameworks.Repo,
  adapter: Ecto.Adapters.Postgres,
  types: RhoFrameworks.PostgrexTypes
```

Postgrex types module (`apps/rho_frameworks/lib/rho_frameworks/postgrex_types.ex`):

```elixir
Postgrex.Types.define(
  RhoFrameworks.PostgrexTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  json: Jason
)
```

Migrations: most existing migrations should run unchanged on Postgres
since they use Ecto-agnostic syntax. Audit for SQLite-isms:
- `uuid()` defaults — switch to `fragment("gen_random_uuid()")` or rely
  on `Ecto.UUID.generate/0` in `before_insert` callbacks (same as today).
- JSON columns: SQLite stores TEXT, Postgres uses JSONB. Schema field
  type stays `:map` — Ecto handles encoding either way.
- Timestamp precision: SQLite is ms, Postgres can be µs. Existing
  `:utc_datetime_usec` declarations work on both.

Add a first-time migration to enable pgvector:

```elixir
# apps/rho_frameworks/priv/repo/migrations/<ts>_enable_pgvector.exs
def up, do: execute("CREATE EXTENSION IF NOT EXISTS vector")
def down, do: execute("DROP EXTENSION IF EXISTS vector")
```

Data migration: dev environments can drop & recreate
(`mix ecto.drop && mix ecto.create && mix ecto.migrate`). For any
existing prod data, `pg_restore` from a `pg_dump` of a freshly-converted
SQLite → Postgres dump (e.g. via `pgloader`). Document this in the
runbook section of the PR.

### 1. Extract `rho_python`

New umbrella app: `apps/rho_python/`.

Layout:

```
apps/rho_python/
├── mix.exs
├── lib/
│   ├── rho_python.ex                # Public API
│   └── rho_python/
│       ├── application.ex           # Owns pythonx + erlang_python init
│       └── deps.ex                  # Dep aggregation
└── test/
```

`mix.exs` deps: `pythonx`, `erlang_python`. No umbrella deps.

Public API (`lib/rho_python.ex`):

```elixir
defmodule RhoPython do
  @doc "Declare Python deps (idempotent). Call from consumer Application.start/2."
  @spec declare_deps([String.t()]) :: :ok
  def declare_deps(deps) when is_list(deps), do: ...

  @doc "Returns true once Pythonx.uv_init has finished."
  @spec ready?() :: boolean()
  def ready?(), do: ...

  @doc "Block-until-ready helper for use inside server init/1."
  @spec await_ready(timeout()) :: :ok | {:error, :timeout}
  def await_ready(timeout \\ 30_000), do: ...
end
```

Internal mechanism (chosen pattern):

- Consumer apps call `RhoPython.declare_deps/1` synchronously from their
  `Application.start/2`, writing to a `:persistent_term` registry.
- `RhoPython.Application` does NOT init pythonx eagerly. Instead, the
  first caller of `await_ready/1` (or the embeddings server's init)
  triggers a one-shot init that gathers all currently-declared deps
  into a single pyproject and calls `Pythonx.uv_init/1`.
- Subsequent `await_ready/1` calls return immediately.
- Avoids startup-order coordination problems.

Refactoring step:

- Move `init_pythonx/0`, `init_erlang_python/0`,
  `export_env_keys_to_python/0`, `maybe_init_python/0`,
  `maybe_init_erlang_python/0` from `Rho.Stdlib.Application` to
  `RhoPython.Application`.
- The current gating ("init only if any agent uses `:python` plugin")
  becomes: stdlib calls `RhoPython.declare_deps(...)` only if any agent
  uses `:python` — same conditional, different location.
- `Rho.Stdlib.Tools.Python` stays in stdlib but no longer triggers init
  itself; it just calls `Pythonx.eval/2` and assumes pythonx is ready
  (or uses `RhoPython.await_ready/1` defensively).

Verification: existing `:python`-plugin tests must pass after the move.

### 2. Schema migration (embedding column + HNSW index)

Add to `skills` table:

- `embedding` `vector(384)` — pgvector native type. Nullable.
- `embedding_text_hash` BYTEA — SHA-256 of the source text used to
  produce the embedding, nullable. Used to detect when name/description
  changes invalidate the embedding.
- `embedded_at` `timestamp(6) with time zone`, nullable.

Migration file:
`apps/rho_frameworks/priv/repo/migrations/<ts>_add_skill_embeddings.exs`

```elixir
def change do
  alter table(:skills) do
    add :embedding, :vector, size: 384
    add :embedding_text_hash, :binary
    add :embedded_at, :utc_datetime_usec
  end

  # HNSW for cosine similarity. m=16, ef_construction=64 are pgvector
  # defaults — adjust after tuning against real data.
  execute(
    "CREATE INDEX skills_embedding_idx ON skills USING hnsw (embedding vector_cosine_ops)",
    "DROP INDEX skills_embedding_idx"
  )
end
```

Schema change: `apps/rho_frameworks/lib/rho_frameworks/frameworks/skill.ex`

```elixir
field :embedding, Pgvector.Ecto.Vector
field :embedding_text_hash, :binary
field :embedded_at, :utc_datetime_usec
```

No manual encode/decode helpers needed — `Pgvector.Ecto.Vector` handles
serialization to/from `[float()]` lists transparently.

### 3. `rho_embeddings` app

New umbrella app: `apps/rho_embeddings/`.

`mix.exs` deps: `{:rho_python, in_umbrella: true}`. Nothing else from
the umbrella; this app is a focused library.

Public API (`lib/rho_embeddings.ex`):

```elixir
defmodule RhoEmbeddings do
  @spec embed_many([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  @spec ready?() :: boolean()
  @spec model_name() :: String.t()
end
```

(No `cosine/2` API — that work moves to SQL via pgvector's `<=>`
operator. See step 5.)

`RhoEmbeddings.Application` calls
`RhoPython.declare_deps(["fastembed==0.7.3", "numpy>=2.0"])` in
`start/2` BEFORE adding `RhoEmbeddings.Server` to its supervision tree.

Server design (`lib/rho_embeddings/server.ex`):

- `RhoEmbeddings.Server` — `GenServer`, `restart: :transient`.
- One singleton instance under the app's supervisor.
- State: `%{model_name: String.t(), loaded?: boolean()}` — the actual
  Python model handle lives in pythonx globals (keyed
  `__rho_embed_model__`); Elixir state just tracks readiness.
- `init/1`:
  1. `RhoPython.await_ready(30_000)` — wait for pythonx to finish init.
  2. Spawn a `Task` to load the model asynchronously.
  3. Reply `{:error, :not_ready}` to `embed_many` calls while loading.
- `embed_many/1`: serializes through `GenServer.call/3` (so all callers
  funnel through one process — matches pythonx's GIL contract).
- `handle_call(:embed, ...)`: invokes `Pythonx.eval/2`, decodes vectors,
  returns. Long calls run on dirty schedulers via the pythonx NIF.

Pseudo-code for the load eval:

```python
from fastembed import TextEmbedding
__rho_embed_model__ = TextEmbedding(
    model_name="sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
)
list(__rho_embed_model__.embed(["warmup"]))
```

Pseudo-code for the embed eval (called per batch):

```python
import numpy as np
__vecs = list(__rho_embed_model__.embed(batch))
[v.tolist() for v in __vecs]
```

### 4. Inline embedding on upsert

`apps/rho_frameworks/lib/rho_frameworks/library.ex`:

- `apps/rho_frameworks/mix.exs` adds `{:rho_embeddings, in_umbrella: true}`.
- In `upsert_skill/2` (and any other path that creates/edits skill
  name/description), compute the embedding text:
  `"#{skill.name}\n#{skill.description || ""}"`.
- Hash it (SHA-256) for `embedding_text_hash`.
- Compare against existing hash; if changed (or null), call
  `RhoEmbeddings.embed_many([text])`, write the resulting vector + hash
  + `embedded_at` to the row.
- If `RhoEmbeddings.embed_many/1` returns `{:error, :not_ready}` or
  any other error: log a warning and proceed without setting the
  embedding. The row is still saved; backfill mix task picks it up
  later.
- Add `embedding`, `embedding_text_hash`, `embedded_at` to
  `Skill.changeset/2` cast list (but NOT to user-provided params —
  these are server-side only).

Performance note: 1.5 ms per single embed is invisible — keep the call
synchronous inside the upsert transaction. No async pipeline needed.

### 5. Cosine pre-filter (SQL-side via pgvector)

`apps/rho_frameworks/lib/rho_frameworks/library.ex` —
`find_semantic_duplicates_via_llm/1`:

Replace `candidate_pairs_for_semantic/2` with a **SQL-level pairwise
cosine query** via pgvector's `<=>` operator (cosine distance, lower =
more similar). For a single library:

```elixir
# threshold expressed as cosine distance: 1 - cosine_similarity
# 0.55 cosine_similarity → 0.45 cosine_distance
@semantic_distance_threshold 0.45

def candidate_pairs_for_semantic(library_id) do
  from(s1 in Skill,
    join: s2 in Skill, on: s2.library_id == s1.library_id and s2.id > s1.id,
    where: s1.library_id == ^library_id,
    where: not is_nil(s1.embedding) and not is_nil(s2.embedding),
    where: fragment("? <=> ?", s1.embedding, s2.embedding) < ^@semantic_distance_threshold,
    select: {s1, s2}
  )
  |> Repo.all()
end
```

Postgres handles the matmul efficiently (HNSW index speeds the
filter). For 1000 skills: sub-100 ms.

**Jaro fallback** for skills missing embeddings:

```elixir
def jaro_fallback_pairs(library_id) do
  from(s in Skill,
    where: s.library_id == ^library_id and is_nil(s.embedding),
    select: s
  )
  |> Repo.all()
  |> apply_existing_jaro_filter()
end
```

Combine both candidate sets, dedup by ID pair, feed to LLM verification
chunks.

Module attrs:

```elixir
@semantic_distance_threshold 0.45
@semantic_jaro_fallback_threshold 0.6
@semantic_chunk_size 40
@semantic_chunk_concurrency 4
@semantic_chunk_timeout_ms 60_000
```

### 6. Backfill mix task

`apps/rho_frameworks/lib/mix/tasks/rho_frameworks.backfill_embeddings.ex`:

```elixir
defmodule Mix.Tasks.RhoFrameworks.BackfillEmbeddings do
  use Mix.Task

  @shortdoc "Compute embeddings for any skills missing them"

  def run(_) do
    Mix.Task.run("app.start")
    # Stream skills where embedding IS NULL
    # In batches of 100, build embed_many input, write back
  end
end
```

- Stream-process `where(s, [s], is_nil(s.embedding))`.
- Batch size 100; commit per batch.
- Idempotent: re-running picks up only skills still missing.
- Log progress every batch.

### 7. Tests

- `apps/rho_python/test/` — minimal: ensure `declare_deps/1` is
  idempotent; `ready?/0` flips after init; the existing `:python`
  plugin still works against the extracted runtime.
- `apps/rho_embeddings/test/` — server unit tests with a fake pythonx
  shim (replace the eval call seam with a deterministic stub).
- `apps/rho_frameworks/test/rho_frameworks/library_test.exs`:
  - Existing dedup tests (`detects slug prefix overlaps`,
    `dismissed pairs are excluded`) must keep passing.
  - Add: skill with embedding gets cosine-checked via pgvector (mock
    the LLM, assert pair is found via embedding, not jaro).
  - Add: skill without embedding falls back to jaro.
- Mock the embeddings module via Application env override for
  deterministic tests:
  - `Application.put_env(:rho_frameworks, :embeddings_mod, FakeEmbeddings)`
  - `FakeEmbeddings.embed_many/1` returns canned vectors per input
    text.
- Skip the actual fastembed-loading path in tests by default. Don't
  download a 210 MB model in CI.
- CI Postgres: use `pgvector/pgvector:pg17` Docker image for tests;
  `mix ecto.create && mix ecto.migrate` runs the `CREATE EXTENSION
  vector` migration.

### 8. Config knobs (incl. Neon-specific)

`config/runtime.exs`:

```elixir
db_url = System.fetch_env!("DATABASE_URL")

config :rho_frameworks, RhoFrameworks.Repo,
  url: db_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
  prepare: :unnamed,
  parameters: [application_name: "rho_frameworks"],
  ssl: System.get_env("DB_SSL", "true") == "true",
  ssl_opts: [verify: :verify_none],
  socket_options: [:inet6]

config :rho_embeddings,
  enabled: System.get_env("RHO_EMBEDDINGS_ENABLED", "true") in ["true", "1"],
  model: System.get_env("RHO_EMBEDDINGS_MODEL",
    "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2")
```

Notes:

- `prepare: :unnamed` is **required** when using Neon's pooled
  endpoint (PgBouncer transaction-pooling drops named prepared
  statements between transactions). Harmless on direct/session-pooled
  endpoints, so safe as a default.
- `DATABASE_URL` for dev: either local Postgres
  (`postgres://localhost/rho_dev`) or a Neon dev branch URL.
- `RHO_EMBEDDINGS_ENABLED=false` skips the model load; all
  `embed_many/1` calls return `{:error, :disabled}`. Dedup falls back
  to jaro entirely. Useful in CI, lightweight deploys, hosts that
  don't ship Python wheels.

## Order of work

The work is grouped into three phases. Each phase is a separate
commit/PR and stands on its own — verify and ship before starting the
next.

### Phase 1 — Postgres + pgvector migration (Step 1)

Independently shippable refactor. Pure adapter swap, no behavior change.
Highest setup cost (local Postgres, dev DB recreate) but smallest blast
radius if reverted. Lands first because every later step targets the
new DB.

1. **Migrate `rho_frameworks` from `ecto_sqlite3` to
   `postgrex` + `pgvector`.** Update mix.exs deps, swap adapter, add
   Postgrex types module, add `CREATE EXTENSION vector` migration, run
   existing migrations against a fresh Postgres instance, verify all
   tests pass.

**Done when:** `mix test --app rho_frameworks` is green against
Postgres; `CREATE EXTENSION vector` runs cleanly; pgvector type is
loadable.

### Phase 2 — Extract `rho_python` (Step 2)

Independently shippable refactor. No behavior change.

2. **Extract `rho_python`.** Move pythonx + erlang_python lifecycle out
   of `Rho.Stdlib.Application`. Define `declare_deps/1`, `ready?/0`,
   `await_ready/1`. Update `rho_stdlib` to call `declare_deps/1` from
   its own `Application.start/2` based on agent plugin config. Verify
   the `:python` plugin still works end-to-end.

**Done when:** `mix test --app rho_stdlib` passes; `:python` and
`:py_agent` plugin tests still green; nothing else in the umbrella
imports `Rho.Stdlib.Application` for Python lifecycle.

### Phase 3 — Embedding feature (Steps 3–9)

Depends on Phases 1 and 2. Adds the actual dedup capability.

3. **Schema migration:** add `embedding vector(384)`,
   `embedding_text_hash`, `embedded_at` columns + HNSW index.
4. **Create `rho_embeddings` app.** `mix.exs` declares
   `{:rho_python, in_umbrella: true}`. Implement `RhoEmbeddings.Server`
   + the public API (`embed_many/1`, `ready?/0`, `model_name/0`).
   Calls `RhoPython.declare_deps(["fastembed==0.7.3", "numpy>=2.0"])`
   from its `Application.start/2`.
5. **Inline embed-on-upsert** in `library.ex`. Hash-based invalidation
   ships in v1.
6. **Backfill mix task**; run on dev DB to populate existing skills.
7. **SQL-level cosine pre-filter** in
   `find_semantic_duplicates_via_llm/1` with jaro fallback.
8. **Tests** for each new app + the dedup integration.
9. **Tune cosine threshold + HNSW params** against real data.

**Done when:** dedup eval against the default library surfaces
cross-lingual / cross-name pairs that the jaro filter misses, with
acceptable precision.

## Risks / open questions

- **Postgres migration data loss / quirks:** existing dev `.db` data
  needs `pgloader` or manual recreation. Production data (if any) needs
  documented dump/restore. Audit migrations for SQLite-isms (default
  values, type coercion).
- **Neon prepared-statement quirk:** `prepare: :unnamed` mandatory if
  using pooled endpoint. Documented above; one-line config.
- **Neon cold start on autosuspend:** 0.5–2 s wake-up on first request
  after idle. Mitigations: disable autosuspend on prod (paid plans), or
  set min compute > 0, or accept and add a healthcheck pre-warm.
- **Pythonx dep aggregation:** chosen pattern (b) — consumer apps
  register synchronously via `:persistent_term`, init runs lazily on
  first `await_ready/1` call. Avoids startup-order coordination.
- **Model download size in CI/Docker:** 210 MB model weights download
  on first call. Solutions: pre-download in Dockerfile, mount a cached
  volume, or set `RHO_EMBEDDINGS_ENABLED=false` in CI.
- **HNSW index parameters:** defaults (`m=16`, `ef_construction=64`)
  are reasonable. May need tuning on large libraries; revisit when
  recall/precision evaluations are run.
- **Cosine threshold tuning:** 0.55 cosine_similarity (0.45
  cosine_distance) is a starting guess. MiniLM-multi paraphrase pairs
  cluster 0.65–0.9; distinct concepts <0.4. Likely needs adjustment on
  first eval.
- **Hash-based invalidation phase 2:** v1 re-embeds when
  `embedding IS NULL` *or* the text hash differs. If a skill name
  changes after embedding, the embedding is replaced inline on upsert.
  Backfill task handles the `IS NULL` case.

## Future direction

This work sets up two larger pieces:

### Skill semantic search

`RhoEmbeddings` + pgvector are immediately reusable for: skill-search
typeahead in the LV, role-profile auto-suggest "similar skills",
library diff "approximate matches". With pgvector + HNSW, a typeahead
query becomes:

```elixir
def search_skills(library_id, query_text, top_k \\ 10) do
  query_vec = RhoEmbeddings.embed_many([query_text]) |> elem(1) |> hd()

  from(s in Skill,
    where: s.library_id == ^library_id,
    order_by: fragment("? <=> ?", s.embedding, ^query_vec),
    limit: ^top_k
  )
  |> Repo.all()
end
```

Sub-10 ms even at 100K skills.

### `rho_context` (RLM-style context primitives)

Inspired by [Recursive Language Models](https://alexzhang13.github.io/blog/2025/rlm/),
the project's eventual direction is to treat context as a manipulable
artifact rather than a monolithic prompt. The natural primitives:

- `RhoContext.peek/2` — sample structure of a large value
- `RhoContext.grep/2` — literal regex search
- `RhoContext.semantic_search/2` — embedding-backed (uses
  `rho_embeddings` + pgvector)
- `RhoContext.partition/2` — split by structure for fan-out
- `RhoContext.sub_call/2` — recursive LM call with isolated context

These compose into a `RecursiveTurnStrategy` that sits alongside
`Rho.TurnStrategy.Direct` and `.TypedStructured`.

`rho_python` and `rho_embeddings` are direct prerequisites. **Don't
build `rho_context` speculatively.** Ship dedup. The next time a
feature wants semantic retrieval over a large context (RAG over
uploaded docs, agent-side knowledge lookup, library skill-search at
scale), that's the moment to lift these primitives into a focused app.

### Model upgrades

If multilingual quality becomes a bottleneck, swap to
`google/embeddinggemma-300m` (1.24 GB, materially better quality,
Apache-2.0, Matryoshka truncation for cheaper cosine math). The
`RHO_EMBEDDINGS_MODEL` env var makes this a config swap + backfill,
not a code change.
