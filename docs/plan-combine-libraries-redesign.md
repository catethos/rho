# Combine Libraries Redesign — Preview/Resolve/Commit

## Problem

Current `combine_libraries` blindly copies all skills, then requires separate
`find_duplicates` + N × `merge_skills` calls. Wastes LLM turns and gives the
user no say before duplicates are created.

## Design

Three-phase approach: **preview → resolve → commit**.

### Phase 1: `Library.combine_preview/3` (no DB writes)

Collects skills from all sources, runs dedup detection across them (reusing
existing `find_slug_prefix_overlaps` + `find_word_overlap_in_category`), and
returns:

```elixir
%{
  clean: [%{skill: skill, source_library: lib}],
  conflicts: [
    %{
      skill_a: %{id, name, category, description, source_library_id, source_library_name,
                  level_count, role_count},
      skill_b: %{...same...},
      confidence: :high | :medium | :low,
      detection_method: :slug_prefix | :word_overlap
    }
  ],
  sources: [%{id, name, skill_count}],
  stats: %{total: N, clean: N, conflicted: N}
}
```

Key: detection runs on *source* skills (cross-library), not on an already-created
library. No DB writes.

### Phase 2: `Library.combine_commit/5`

Takes org_id, source_ids, name, opts, and a `resolutions` list:

```elixir
resolutions = [
  %{"skill_a_id" => id, "skill_b_id" => id, "action" => "merge", "keep" => id},
  %{"skill_a_id" => id, "skill_b_id" => id, "action" => "keep_both"},
  %{"skill_a_id" => id, "skill_b_id" => id, "action" => "pick", "keep" => id}
]
```

- `merge`: copy keep skill, absorb the other's proficiency levels
- `keep_both`: copy both as-is
- `pick`: copy only the kept one, skip the other

Uses existing `derive_library` logic but skips conflicted skills from the
normal copy pass, then applies resolutions.

### Phase 3: Tool layer changes

**Replace** `combine_libraries` tool with two tools:

1. `combine_libraries` — calls `combine_preview`. If no conflicts, auto-commits
   and returns the library. If conflicts, returns the preview with conflict
   details so the agent can present them.

2. `combine_libraries_commit` — accepts resolutions JSON, calls `combine_commit`.
   Returns the created library with id.

**Keep** `find_duplicates`, `merge_skills`, `dismiss_duplicate` unchanged —
they're still useful for post-hoc dedup on any library.

## Files to change

1. `apps/rho_frameworks/lib/rho_frameworks/library.ex`
   - Add `combine_preview/3`
   - Add `combine_commit/5`
   - Keep `combine_libraries/4` but make it delegate to preview+auto-commit

2. `apps/rho_frameworks/lib/rho_frameworks/tools/library_tools.ex`
   - Rewrite `combine_libraries` tool to use preview, auto-commit if clean
   - Add `combine_libraries_commit` tool
