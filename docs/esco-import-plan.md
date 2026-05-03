# ESCO Public Skills Framework Import — Plan

## Goal

Make the [ESCO v1.2.1 classification](https://esco.ec.europa.eu/) (~13,960 skills, ~3,008 occupations, ~126,000 occupation↔skill links) available inside `rho_frameworks` as a **public skills library + occupation set** that every user can read but cannot write.

Primary use case: **given a role, find the related skills** (essential + optional). Secondary: skill search across a curated, semantically-embedded corpus.

## Decisions confirmed

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Option B (lossy flatten)** — no schema change for the import | The graph structure (Skill→Skill broader, Skill→SkillGroup, skill↔skill prerequisites) is preserved only enough to feed `category`/`cluster`. The remainder is dropped. Use case is role→skill lookup, not graph navigation. |
| 2 | **Dedicated System organization** owns the public library/roles | Keeps `cloverethos@gmail.com`'s personal org clean; one obvious owner for all future public datasets. |
| 3 | **All 3,008 ESCO occupations imported** as `role_profiles` with `visibility: "public"` | Required for the role→skill lookup. |
| 4 | **One ESCO version live at a time.** No multi-version role support in this iteration. | `role_profiles` has no `library_id` / version / external-id (initial_schema.exs:135-173). A second `--version` would either collide on `(organization_id, name)` or merge across versions silently. Re-importing the same version is a no-op; bumping versions is deferred to a future schema change. |
| 5 | **Hide public role profiles in LV list screens** by passing `include_public: false` at the call sites. **Do NOT change the `Roles.list_role_profiles/2` default.** | Flipping the global default also affects tools (e.g. `manage_role list` in `role_tools.ex:61-64`) that should keep discovering public roles. The UI list screens render delete affordances, which is broken UX for public roles, so they are the only callers that need the flag. |
| 6 | **Slug uniqueness via URI suffix** (`<slugified-name>-<uri-tail-6>`) **AND** identity-by-id everywhere downstream | ~200 ESCO skills share `preferredLabel`. Slug suffix keeps DB rows distinct, but several flows currently key by `skill.name` (compare/clone/org_view) and would still silently merge them — see "Identity fixes" below. |
| 7 | **Embeddings out of scope** for the import task; reuse `mix rho_frameworks.backfill_embeddings` after import. | 13.9k embedding API calls is a separate, batched, resumable concern. |
| 8 | **Add embeddings to `RoleProfile`** as a follow-up step (separate migration + generalized backfill task). Embed `name + description + purpose`. | Role discovery via "find related roles for this query" needs vector search. ESCO supplies 3,008 distinct occupations; pure text search on `name` would miss synonyms. `description` carries domain context; `purpose` (populated by save flows in `role_tools.ex:179-185`) carries authored intent for non-ESCO roles. |
| 9 | **Publish the public library only after import succeeds.** Create as private + mutable, run import, then flip `visibility: "public"`, `immutable: true`, set `published_at`. | A crashed mid-import otherwise leaves a partially-populated public library visible to every user. |

## Data shape (recap from investigation)

ESCO ships 19 CSVs. We use four of them:

| File | Rows used | Maps to |
|------|-----------|---------|
| `skills_en.csv` | ~13,960 (filter `conceptType == "KnowledgeSkillCompetence"`) | `skills` rows |
| `skillsHierarchy_en.csv` | denormalized walk of pillar relations (L0/L1/L2/L3) | enriches `skills.category` (L1) and `skills.cluster` (L2) by URI lookup |
| `occupations_en.csv` | ~3,008 | `role_profiles` rows |
| `ISCOGroups_en.csv` | lookup by 4-digit code | enriches `role_profiles.role_family` |
| `occupationSkillRelations_en.csv` | ~126,000 | `role_skills` rows; `essential` → `required: true`, `optional` → `required: false` |

Ignored (option B): `broaderRelationsSkillPillar_en.csv`, `skillSkillRelations_en.csv`, `skillGroups_en.csv`, plus all subset collections (digital/green/transversal/language/research/digComp).

## Schema impact

**For the import itself: none.** All ESCO-specific fields ride along in existing `metadata` jsonb columns.

**For the role-embedding follow-up: one migration** adding `embedding`, `embedding_text_hash`, `embedded_at` to `role_profiles` (mirrors the columns added to `skills` in `20260429113525_add_skill_embeddings.exs`, including the raw-SQL HNSW index). Details under **Role embeddings (follow-up)** below.

### Identity & code fixes required *alongside* the import

The import doesn't change schema, but several code paths must be updated for ESCO data to behave correctly. These are **part of the import task's PR**, not separate work:

1. **`clone_role_skills/2`** at `apps/rho_frameworks/lib/rho_frameworks/roles.ex:466-472` and **`clone_skills_for_library/2`** at `roles.ex:517-520` — fetch by org only. Public ESCO roles selected via `PickTemplate` / `RoleTools` clone return empty data. Change the where clause to `where: (rp.organization_id == ^org_id or rp.visibility == "public") and rp.id in ^role_profile_ids`.
2. **Identity-by-name → identity-by-id** in:
   - `compare_role_profiles/2` (`roles.ex:205-250`)
   - `org_view/1` (`roles.ex:274-352`)
   - `clone_role_skills/2` row map (`roles.ex:476-499`)
   - `clone_skills_for_library/2` row map (`roles.ex:427-439`)
   Key by `skill.id` (or `metadata["esco_uri"]`) so ESCO duplicates with the same `preferredLabel` don't silently collapse.
3. **`Library.search_skills_across/3`** at `apps/rho_frameworks/lib/rho_frameworks/library.ex:725-751` — currently org-scoped. Add `or l.visibility == "public"` (or an `include_public` opt) so the `browse_library` tool actually finds ESCO skills.
4. **`Library.library_summary/1`** (`library.ex:57-91`) is called by `browse_library` with no query and concatenates names of every skill in every visible library. With 14k ESCO skills this will blow agent prompt budgets. Either filter `visibility == "public"` libraries out of the no-query path, or cap the per-library skill count, or require an explicit `library_name` for public libraries.

ESCO metadata layout:

```elixir
# Skill.metadata
%{
  "esco_uri" => "http://data.europa.eu/esco/skill/...",
  "skill_type" => "knowledge" | "skill/competence",
  "reuse_level" => "transversal" | "cross-sector" | "sector-specific" | "occupation-specific",
  "alt_labels" => ["...", "..."],
  "level_3_uri" => "...",         # nearest hierarchy parent
  "source" => "ESCO v1.2.1"
}

# RoleProfile.metadata
%{
  "esco_uri" => "http://data.europa.eu/esco/occupation/...",
  "isco_code" => "2654",
  "isco_label" => "Film, stage and related directors and producers",
  "alt_labels" => ["..."],
  "regulated_profession_note" => "...",
  "source" => "ESCO v1.2.1"
}
```

`Skill.proficiency_levels` is left as `[]`. The wizard/agent surfaces that assume PLs exist need a smoke test (called out under "validation").

## File-level changes

### New files

1. **`apps/rho_frameworks/lib/mix/tasks/rho.import_esco.ex`** — Mix task entry point.
2. **`apps/rho_frameworks/lib/rho_frameworks/import/esco.ex`** — Pure import logic, broken out so tests don't need the Mix shell.
3. **`apps/rho_frameworks/test/rho_frameworks/import/esco_test.exs`** — fixtures: 4 tiny CSVs derived from real ESCO rows.
4. **`apps/rho_frameworks/priv/repo/migrations/<ts>_create_system_organization.exs`** — seeds the `system` organization (idempotent: insert-on-conflict by slug).

### Modified files

1. **`apps/rho_frameworks/mix.exs`** — add `{:nimble_csv, "~> 1.2"}` (handles ESCO's quoted multi-line `altLabels`).
2. **`apps/rho_frameworks/lib/rho_frameworks/roles.ex`** — code fixes from "Identity & code fixes" above:
   - `clone_role_skills/2` and `clone_skills_for_library/2` accept public roles.
   - `compare_role_profiles/2`, `org_view/1`, and clone row builders key by `skill.id` not `skill.name`.
   - **Default of `list_role_profiles/2` stays `include_public: true`.** (Reverses the earlier plan — that flag is also load-bearing for tools.)
3. **`apps/rho_frameworks/lib/rho_frameworks/library.ex`** — `search_skills_across/3` accepts public libraries (or grows an `include_public` opt). `library_summary/1`'s no-query path filters/caps public libraries.
4. **LV callers** in `apps/rho_web/lib/rho_web/live/` — pass `include_public: false` explicitly. The role list / settings screens are the only callers that should hide ESCO roles:
   - `app_live.ex:217-223`
   - `role_profile_list_live.ex:10-29`
   - `app_live/settings_events.ex:8-12` (was missed in the earlier draft)
   Add a "Browse public roles" toggle later in a follow-up; out of scope here.

## Algorithm

### Step 1 — Bootstrap the System organization

```elixir
# Migration — runs once, idempotent
%Organization{}
|> Organization.changeset(%{name: "System", slug: "system", personal: false})
|> Repo.insert!(on_conflict: :nothing, conflict_target: :slug)
```

The System org has no memberships. It owns public libraries and public role profiles.

### Step 2 — Parse the CSVs (streaming)

Use `NimbleCSV.RFC4180`. ESCO's `altLabels`, `description`, and `scopeNote` columns embed `\n`s inside quotes — `NimbleCSV` handles this; hand-rolled splits do not.

Stream `skills_en.csv` filtering to `KnowledgeSkillCompetence` only. Memory-bound: build the URI→hierarchy map once from `skillsHierarchy_en.csv`, then stream skills and join on the fly.

### Step 3 — Build (or fetch) the library, **private + mutable for now**

```elixir
attrs = %{
  name: "ESCO Skills & Occupations",
  description: "European Skills, Competences, Qualifications and Occupations classification (v1.2.1). Source: https://esco.ec.europa.eu/ — © European Union, CC-BY 4.0.",
  type: "skill",
  visibility: "private",        # flipped to "public" in Step 7 only after success
  organization_id: system_org.id,
  source_key: "esco-1.2.1",
  version: "2026.1",            # versioning rule from Library.validate_version_format/1
  immutable: false,             # set true in Step 7 once import is complete
  is_default: false,
  metadata: %{"attribution" => "© European Union, https://esco.ec.europa.eu/", "license" => "CC-BY 4.0"}
}

library =
  case Repo.get_by(Library, organization_id: system_org.id, name: attrs.name, version: attrs.version) do
    nil -> %Library{} |> Library.changeset(attrs) |> Repo.insert!()
    existing -> existing  # idempotent rerun
  end
```

(Replaces the earlier `Repo.insert!()` which would crash on the unique index `(organization_id, name, version)` on rerun.)

### Step 4 — Bulk insert skills (chunk 1000) — **prefetch + insert_all returning pattern**

Re-run safety: when `on_conflict: :nothing` skips a row, `insert_all` does **not** return it. So building `%{esco_uri => skill_id}` from inserted rows alone breaks reruns. Use the same pattern as `apps/rho_frameworks/lib/mix/tasks/rho.import_framework.ex:206-328`:

```elixir
# 1. Prefetch existing rows for this library, key by esco_uri (stored in metadata).
existing =
  Repo.all(
    from s in Skill,
      where: s.library_id == ^library.id,
      select: {fragment("?->>'esco_uri'", s.metadata), s.id}
  )
  |> Map.new()

# 2. Filter out already-inserted URIs.
to_insert =
  skills
  |> Stream.reject(fn s -> Map.has_key?(existing, s.esco_uri) end)
  |> Stream.chunk_every(1000)

# 3. Insert remaining; collect {esco_uri, id} from `returning: [:id, :metadata]`.
inserted =
  to_insert
  |> Enum.flat_map(fn chunk ->
    {_n, rows} =
      Repo.insert_all(Skill, build_skill_rows(chunk, library.id),
        on_conflict: :nothing,
        conflict_target: [:library_id, :slug],
        returning: [:id, :metadata])
    Enum.map(rows, fn r -> {r.metadata["esco_uri"], r.id} end)
  end)
  |> Map.new()

skill_by_uri = Map.merge(existing, inserted)
```

Slug strategy: `slug = "#{slugify(name)}-#{String.slice(uri_tail, -6, 6)}"` so `manage-staff-a4f2c1` and `manage-staff-b7c0d3` coexist.

Fallback: `skills.category` is `NOT NULL` (initial_schema.exs:112). When the hierarchy join misses a URI, default `category` to the skill's `reuse_level` (or `"Uncategorized"` as a last resort) so `insert_all` doesn't blow up.

### Step 5 — Bulk insert role profiles (chunk 1000) — same prefetch pattern

Identical structure to Step 4: prefetch existing role profiles for the System org keyed by `metadata->>'esco_uri'`, filter, `insert_all` with `returning: [:id, :metadata]`, merge maps. `name` collisions handled by suffixing (`Director-A4F2C1`) for the unique index on `(organization_id, name)`.

Build `%{esco_uri => role_profile_id}` (the merged map) for step 6.

### Step 6 — Bulk insert role-skill links (chunk 5000)

PostgreSQL parameter limit is 65,535. Each `role_skill` row has 7 fields → safe chunk = 5,000 rows × 7 = 35k params.

**De-duplicate first.** ESCO sometimes lists `(occupation_uri, skill_uri)` more than once with different `relationType`. With `on_conflict: :nothing` the resulting `required` flag is order-dependent. Collapse duplicates upfront, preferring `essential`:

```elixir
relations =
  raw_relations
  |> Enum.group_by(&{&1.occupation_uri, &1.skill_uri})
  |> Enum.map(fn {_k, group} ->
    case Enum.find(group, &(&1.relation_type == "essential")) do
      nil -> hd(group)
      essential -> essential
    end
  end)
```

```elixir
relations
|> Stream.chunk_every(5000)
|> Stream.each(fn chunk ->
  rows =
    chunk
    |> Enum.flat_map(fn rel ->
      with rp_id when not is_nil(rp_id) <- rp_by_uri[rel.occupation_uri],
           sk_id when not is_nil(sk_id) <- skill_by_uri[rel.skill_uri] do
        [%{
          id: Ecto.UUID.generate(),
          role_profile_id: rp_id,
          skill_id: sk_id,
          required: rel.relation_type == "essential",
          min_expected_level: 1,
          weight: 1.0,
          inserted_at: now,
          updated_at: now
        }]
      else
        _ -> []   # skip unknown URI either side; log a count at the end
      end
    end)

  Repo.insert_all(RoleSkill, rows, on_conflict: :nothing,
                  conflict_target: [:role_profile_id, :skill_id])
end)
|> Stream.run()
```

### Step 7 — Publish the library (only after all inserts succeed)

```elixir
library
|> Library.changeset(%{
  visibility: "public",
  immutable: true,
  published_at: DateTime.utc_now()
})
|> Repo.update!()
```

If any earlier step crashed, the library remains `private` + `mutable` and is invisible to other users. The next run resumes from where it stopped (idempotent inserts) and reaches this step.

### Step 8 — Print summary

```
Import complete (ESCO v1.2.1):
  Library:        ESCO Skills & Occupations (id: …, visibility: public, immutable: true)
  Skills:         13,960 inserted, 0 skipped
  Role Profiles:  3,008 inserted, 0 skipped
  Role-Skill:     124,742 inserted, 1,309 dropped (unmapped URI), N collapsed (duplicate pairs)
Next: mix rho_frameworks.backfill_embeddings
```

## Idempotency

- System org migration uses `on_conflict: :nothing, conflict_target: :slug`.
- Library upsert by `(organization_id, name, version)` matches the existing unique index.
- Skill `insert_all` uses `on_conflict: :nothing, conflict_target: [:library_id, :slug]`.
- RoleProfile `insert_all` same with `(organization_id, name)`.
- RoleSkill same with `(role_profile_id, skill_id)`.

Running the task twice is a no-op. Running with a new `--version 2026.2` creates a new library row (existing one is `immutable: true` and stays as the prior published version).

## Mix task interface

```bash
# default
mix rho.import_esco /path/to/esco-csv-dir

# overrides
mix rho.import_esco --dir /path --version 2026.2 --dry-run

# parse only, no DB writes — used by tests
mix rho.import_esco --dir /path --dry-run
```

`--dry-run` parses every file, builds the lookups, and prints the summary numbers without touching the DB.

## How to run it (laptop → Neon branch → Neon main)

The production DB is **external Neon** (`fly.toml`). The Fly app ships as a `mix release` (`Dockerfile`: `mix release rho_web`), which means **Mix tasks are not available on the Fly machine** — only `bin/rho_web start | eval | remote`. Combined with the 1GB shared-CPU VM serving traffic, the right place to run this is **your laptop, pointing at a Neon branch first, then at main**.

### Recommended sequence

1. **Fork Neon → branch.** Neon supports cheap, near-instant copy-on-write branches. Create one off `main`:

   ```bash
   # One-time: find the project id and (optionally) set context so you don't pass --project-id every call.
   neonctl projects list
   neonctl set-context --project-id <project-id>

   # Create the branch. --parent defaults to the project's primary branch; pass it explicitly to be safe.
   neonctl branches create \
     --project-id <project-id> \
     --parent main \
     --name esco-import-rehearsal

   # Grab the pooled connection string for the new branch.
   export NEON_BRANCH_URL=$(neonctl connection-string esco-import-rehearsal \
     --project-id <project-id> --pooled)
   ```

   Alternative: do the same in the Neon console UI (Project → Branches → "Create branch" from `main`) and copy the connection string. Faster for a one-off rehearsal.

   Tip: stash `NEON_PROJECT_ID` and `NEON_API_KEY` in your `.env`; `neonctl` picks them up automatically and you can drop the explicit `--project-id` flag.

2. **Migrate the branch.** The migrations (System org, future role-embedding columns) only need to run on the branch first:

   ```bash
   DATABASE_URL="$NEON_BRANCH_URL" MIX_ENV=prod \
     mix ecto.migrate
   ```

3. **Dry-run on the branch** to confirm parse counts:

   ```bash
   DATABASE_URL="$NEON_BRANCH_URL" MIX_ENV=prod \
     mix rho.import_esco /path/to/esco-1.2.1 --dry-run
   ```

4. **Real import on the branch.** This is the rehearsal — full row counts, full timing, full publish flip:

   ```bash
   DATABASE_URL="$NEON_BRANCH_URL" MIX_ENV=prod \
     mix rho.import_esco /path/to/esco-1.2.1
   ```

   Inspect: row counts match expected (~13,960 / ~3,008 / ~125k), library is `public`+`immutable`, `role_profiles` are visible to a non-System org via `Roles.list_role_profiles(org_id, include_public: true)`, etc.

5. **Embeddings on the branch** to flush out any model/HNSW index issues:

   ```bash
   DATABASE_URL="$NEON_BRANCH_URL" MIX_ENV=prod \
     mix rho_frameworks.backfill_embeddings --batch 200
   ```

6. **Re-run the importer on the branch** to verify idempotency: zero new inserts, library still `public`+`immutable`.

7. **Promote to main** — once happy:

   ```bash
   # migration on prod Neon via the deployed release
   just migrate

   # data import from laptop, against prod Neon
   DATABASE_URL="$NEON_URL" MIX_ENV=prod \
     mix rho.import_esco /path/to/esco-1.2.1
   DATABASE_URL="$NEON_URL" MIX_ENV=prod \
     mix rho_frameworks.backfill_embeddings --batch 200
   ```

8. **Delete the branch** when verified:

   ```bash
   neonctl branches delete esco-import-rehearsal
   ```

### Why a branch (not just `--dry-run` against prod)

`--dry-run` only validates parsing. It can't catch:
- DB-side issues (`NOT NULL` failures, type mismatches, parameter overflow at chunk boundaries).
- Real wall-clock timing on Neon (laptop→Neon RTT × 14k+ inserts).
- Whether `library_summary/1` actually fits in agent prompt budgets with 14k skills.
- Whether the role-list LV behaves correctly with `include_public: false` once public roles exist.
- Whether `Roles.find_similar_roles/3` (pre-embedding rewrite) explodes at 3k roles.

A Neon branch gives you a copy of prod data + schema for the cost of pointer-level CoW. Use it.

### Guardrails the Mix task should add

- Print connected DB host + System org id + target library `name@version` + visibility before any writes.
- Refuse to publish (Step 7) without `--yes` if the connected database hostname matches a configured "production" pattern (or always require `--yes` and document a `--no-confirm` for tests).
- Log progress per chunk so a long-running import isn't a black box.

## Visibility behavior change

**Earlier draft proposed flipping the `Roles.list_role_profiles/2` default — DON'T.** The flag is also load-bearing for tools (`role_tools.ex:61-64`'s `manage_role list`, the wizard's role-search) that should keep finding ESCO matches.

Instead: pass `include_public: false` **explicitly** at the LV list/refresh sites that render delete affordances:
- `apps/rho_web/lib/rho_web/live/app_live.ex:217-223`
- `apps/rho_web/lib/rho_web/live/role_profile_list_live.ex:10-29`
- `apps/rho_web/lib/rho_web/live/app_live/settings_events.ex:8-12`

Notes:
- `compare_role_profiles/2` is already org-scoped (`roles.ex:205-210`) — no change needed there.
- `get_visible_role_profile!` already does the right thing for single-row reads — leave alone.
- A "Browse public roles" toggle in the LV is out of scope for this task.

## Embeddings (separate, after import)

### Skill embeddings (existing)

```bash
# Backfill all skills with NULL embedding (will pick up the 13,960 new ESCO rows)
mix rho_frameworks.backfill_embeddings --batch 200
```

Existing task already handles batching, ready-checks, and resume. No changes needed for the skill side. Will take a while; can be killed and resumed.

Estimate: 13,960 skills / batch 200 = 70 batches. With a local Pythonx model ~5s/batch → ~6 minutes. With a remote API → depends on rate limits.

### Role embeddings (follow-up)

Add embeddings to `role_profiles` so the wizard can answer "find roles related to this query" by vector similarity instead of LLM-rerank-everything.

**Why this is more than a migration.** `Roles.find_similar_roles/3` (`roles.ex:377-430`) currently:
1. loads **every** visible role profile,
2. concatenates them into a single prompt,
3. asks the LLM to pick the best.

At ~3,008 ESCO roles this overflows prompt budgets and is slow + expensive. The follow-up must:
1. add the embedding columns + index,
2. backfill,
3. **rewrite `find_similar_roles/3`** to do an embedding KNN top-K (e.g. 25) first, then optionally LLM-rerank that small set.

**Migration** — `apps/rho_frameworks/priv/repo/migrations/<ts>_add_role_profile_embeddings.exs`. Mirror `20260429113525_add_skill_embeddings.exs` exactly, including its **raw-SQL HNSW index** (don't use Ecto's `using: :hnsw, with: [...]` form — it's not what the existing migration does):

```elixir
defmodule RhoFrameworks.Repo.Migrations.AddRoleProfileEmbeddings do
  use Ecto.Migration

  def change do
    alter table(:role_profiles) do
      add :embedding, :vector, size: <same dim as Skill>
      add :embedding_text_hash, :binary
      add :embedded_at, :utc_datetime_usec
    end

    execute(
      """
      CREATE INDEX role_profiles_embedding_hnsw_idx
      ON role_profiles USING hnsw (embedding vector_cosine_ops)
      WITH (m = 16, ef_construction = 64)
      """,
      "DROP INDEX IF EXISTS role_profiles_embedding_hnsw_idx"
    )
  end
end
```

**Schema change** — add the three fields + cast list entries to `RoleProfile`. All nullable.

**Embed text strategy** — `name + "\n" + (description || "") + "\n" + (purpose || "")`. Differs from `Skill.skill_text/1` because `RoleProfile` has a richer text surface (`role_profile.ex:17-23`) and existing save flows populate `purpose` (`role_tools.ex:179-185`). Skipping `purpose` discards the most authoritative signal for non-ESCO user roles.

```elixir
defp role_text(%RoleProfile{name: name, description: desc, purpose: purpose}) do
  [name, desc, purpose]
  |> Enum.reject(&(is_nil(&1) or &1 == ""))
  |> Enum.join("\n")
end
```

**Backfill task generalization** — extend `mix rho_frameworks.backfill_embeddings` to accept `--target skill | role | all`. **Default stays `skill`** to preserve current behavior. Parameterize `missing_query/0`, the `Repo.update!/1` line in `embed_batch/1`, and the text builder.

```bash
mix rho_frameworks.backfill_embeddings                      # default: skill (unchanged)
mix rho_frameworks.backfill_embeddings --target role
mix rho_frameworks.backfill_embeddings --target all --batch 200
```

**Idempotency** — `where: is_nil(rp.embedding) or rp.embedding_text_hash != ^current_hash` so edited roles re-embed automatically. (Skills currently only check `is_nil`; consider extending the same check there too, but that's optional.)

**Estimate.** 3,008 roles / batch 200 = 16 batches. Local Pythonx ~5s/batch → ~80 seconds.

**Rewrite of `find_similar_roles/3`** (sketch):

```elixir
def find_similar_roles(org_id, query, opts \\ []) do
  k = Keyword.get(opts, :k, 25)
  query_vec = Embeddings.embed!(query)

  Repo.all(
    from rp in RoleProfile,
      where: rp.organization_id == ^org_id or rp.visibility == "public",
      where: not is_nil(rp.embedding),
      order_by: fragment("? <=> ?", rp.embedding, ^query_vec),
      limit: ^k
  )
  # optional: LLM rerank the top-K for explanation/scoring
end
```

## Test plan

1. **Unit tests** (`apps/rho_frameworks/test/rho_frameworks/import/esco_test.exs`):
   - 30-line CSV fixtures derived from real ESCO data (under `test/fixtures/esco/`).
   - Parses skills, occupations, hierarchy, ISCO groups.
   - Builds rows, asserts category/cluster join, slug suffixing, essential→required mapping.
   - **Asserts duplicate `(occupation_uri, skill_uri)` pairs collapse to a single row, preferring `essential`.**
   - **Asserts unmapped category falls back to `reuse_level` / `"Uncategorized"` rather than crashing on the NOT NULL constraint.**
   - `--dry-run` produces correct summary without DB writes.
2. **Idempotency test**: run the importer twice over the fixture; second run must insert 0 new skills/roles/role-skills and still publish (or leave already-published) the library.
3. **Crash-recovery test**: run with a synthetic crash injected after Step 5; assert library is still `private`+`mutable`. Re-run; assert library ends `public`+`immutable` and counts match.
4. **Integration test**: full import against fixture, asserts row counts, asserts a few known relations resolve correctly (`technical director` essentially needs `theatre techniques`).
5. **Identity-by-id regression tests** for the code fixes:
   - Two skills with identical `name` but different `id` in the same role profile are NOT collapsed by `compare_role_profiles/2` or `org_view/1`.
   - `clone_role_skills/2` of a `visibility: "public"` role from a different org returns the role's skills (not empty).
   - `Library.search_skills_across/3` finds an ESCO skill from a non-System org caller.
6. **Visibility test**: LV role list with `include_public: false` hides public ESCO roles; an explicit `include_public: true` call (e.g. from `manage_role list`) returns them.
7. **Manual smoke (after merge)**:
   - `mix rho.import_esco /path/to/esco --dry-run` on real data — confirms parse counts ≈ 13,960 / 3,008 / 126,000.
   - `mix rho.import_esco /path/to/esco` on a dev DB — wall-clock and final counts; confirm library transitions private→public.
   - Re-run the same command — assert "0 inserted" everywhere.
   - `mix rho_frameworks.backfill_embeddings --batch 200` to fill skill embeddings.
   - Open the role-list LV — ESCO occupations should NOT be visible.
   - Run `manage_role list` via tool path — ESCO occupations SHOULD be visible.
   - Open the wizard "search related skills" path — ESCO skills SHOULD be searchable.
   - Open `browse_library` with no query — confirm prompt size is bounded (ESCO library not naively dumped).

## Risks & open questions (non-blocking)

| Risk | Mitigation |
|------|-----------|
| Wizard / agent surfaces assume `proficiency_levels` is non-empty | Smoke-test the proficiency-rendering paths against an ESCO skill before declaring done. If broken, render a "no proficiency levels defined" empty state. |
| ~1,309 occupation-skill rows reference a skill URI that's a SkillGroup (not a Skill row) | Logged + skipped. Document the count in the summary. |
| Library list will surface "ESCO Skills & Occupations" to every user — could be noisy | Acceptable per goal. If noisy later, add a "system" filter to the libraries LV. |
| **`Library.library_summary/1` no-query path will dump 14k ESCO skill names into agent prompts** | **Addressed in "Identity & code fixes" item #4** — exclude/cap public libraries in the no-query path. |
| `role_profiles` cannot represent multiple ESCO versions concurrently | Decision #4: one version live at a time. Schema work for multi-version is deferred. |
| Storage ≈ 14k skills × ~2KB metadata + 126k role-skill rows × ~150 bytes = ~50MB before embeddings; with 1024-dim float embeddings ~+60MB | Trivial for Postgres / Neon. |
| Need to confirm `validate_version_format/1` accepts `"2026.1"` | The regex is `^\d{4}\.\d+$` — `"2026.1"` matches. ✓ |
| ESCO licensing — distribution requires CC-BY 4.0 attribution | Embedded in `Library.description` and `Library.metadata` (`attribution`, `license` keys). No user-facing render is required by the license, but we surface it on the library detail page if/when one exists. |

## Out of scope (future work)

- A "Browse public roles / skills" UI toggle in the LV.
- **Multi-version ESCO support** — requires adding `library_id` (or a dataset/version identity) to `role_profiles` plus a unique external-id column.
- Importing other ESCO subsets (transversal, digital, green) as separate libraries.
- Importing `skillSkillRelations_en.csv` (essential/optional skill prerequisites) — would require a new `skill_relations` table.
- Importing the SkillGroup taxonomy as first-class rows — Option A territory.
- Multi-language imports (ESCO ships ~28 languages; we use only `_en`).
- Periodic re-import / version-tracking automation.
- Adding `embedding_text_hash`-driven re-embed support to skills (currently only `is_nil` triggers re-embed).

## Acceptance criteria

### Import task
- [ ] `mix rho.import_esco /path/to/esco` runs end-to-end against a clean DB and prints non-zero counts for skills, roles, role-skills.
- [ ] Re-running the task is a no-op (0 inserted, library still `public`+`immutable`).
- [ ] If the task is killed mid-run, the library remains `private`+`mutable`; a subsequent successful run flips it to `public`+`immutable`.
- [ ] System organization exists with `slug: "system"` after the migration.
- [ ] Library `"ESCO Skills & Occupations"` exists with `visibility: "public"`, `immutable: true`, attribution + license recorded in `metadata`.
- [ ] Duplicate ESCO `(occupation_uri, skill_uri)` pairs collapsed deterministically with `essential` preferred.
- [ ] Skills with unmapped hierarchy categories still insert (fallback applied).

### Code fixes (same PR)
- [ ] `Roles.list_role_profiles/2` default unchanged. LV list/refresh sites in `app_live.ex`, `role_profile_list_live.ex`, `app_live/settings_events.ex` pass `include_public: false` explicitly.
- [ ] `Roles.clone_role_skills/2` and `clone_skills_for_library/2` succeed for `visibility: "public"` source roles.
- [ ] `compare_role_profiles/2`, `org_view/1`, and clone row builders key by `skill.id`, not `skill.name`.
- [ ] `Library.search_skills_across/3` finds skills in public libraries.
- [ ] `Library.library_summary/1` no-query path does not dump every public-library skill.
- [ ] `mix test --app rho_frameworks` passes.

### Embeddings
- [ ] `mix rho_frameworks.backfill_embeddings` (default `--target skill`) populates embeddings for the new skills.
- [ ] **(follow-up)** `role_profiles` has `embedding` / `embedding_text_hash` / `embedded_at` columns + raw-SQL HNSW index after migration.
- [ ] **(follow-up)** `mix rho_frameworks.backfill_embeddings --target role` populates embeddings for all 3,008 ESCO roles using `name + description + purpose`.
- [ ] **(follow-up)** `mix rho_frameworks.backfill_embeddings --target all` backfills both skills and roles in one invocation.
- [ ] **(follow-up)** `Roles.find_similar_roles/3` rewritten to use embedding KNN top-K instead of LLM-rerank-everything; verified with a query that matches an ESCO occupation by synonym (e.g. "solicitor" → "lawyer").
