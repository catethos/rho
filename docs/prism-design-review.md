# Prism — Design Review: Multi-Dimensional Role Profiles

> Requesting feedback on the core abstraction. Not implementation details — just whether the model is right.

## Problem

We have a flat `Framework → Skills` model where a "Framework" is simultaneously the skill catalog (what skills exist, what proficiency looks like) and the role requirement (what a job needs). These are different concerns.

The original restructure plan separated them into **Skill Library** (one per org, canonical taxonomy) and **Role Profiles** (skill selections with required levels). But this has two problems:

1. **One skill library per org is too restrictive.** Users create skill libraries with a specific domain in view — "Data Engineering Competencies" or "Leadership Behaviors" — each with full proficiency level definitions. These aren't role profiles, but they're not meant to be the single org-wide taxonomy either. An org might have multiple competency frameworks from different sources (SFIA, internal engineering ladder, HR behavioral competencies). Forcing them into one namespace creates collisions and conceptual mush.

2. **Role profiles are more than skill selections.** A role profile in practice specifies requirements across multiple independent dimensions — not just "needs SQL at level 4" but also psychometric fit, qualifications, accountabilities, and success metrics. Skills are just one requirement dimension.

## Concrete Example: Why This Matters

Consider a "Senior Data Engineer" role profile. A complete picture includes:

| Dimension | Example Requirements |
|-----------|---------------------|
| Technical skills | SQL at level 4, Python at level 3, Spark at level 3 |
| Leadership skills | Stakeholder Management at level 2, Mentoring at level 2 |
| Work interests (RIASEC) | Investigative-Realistic-Conventional |
| Work styles | High analytical_thinking, high attention_to_detail, moderate stress_tolerance |
| Work values | High achievement, high independence |
| Qualifications | CS/Engineering degree, 5+ years data engineering experience |
| Accountabilities | Owns data pipeline reliability, mentors junior engineers |
| Success metrics | Pipeline uptime > 99.5%, query latency P95 < 200ms |

The original plan would only capture the first row. Everything else is either lost or crammed into a freeform metadata field.

## Proposed Model

```
Organization
  │
  ├── (*) Library                          ← typed catalogs
  │     ├── name, description, domain
  │     ├── type: :skill | :psychometric | :qualification | ...
  │     └── (*) Item                       ← entries with type-specific structure
  │           └── type-specific fields + optional proficiency levels
  │
  └── (*) RoleProfile                      ← multi-dimensional role description
        ├── Core identity
        │     name, role_family, seniority_level, seniority_label
        │
        ├── Role context (rich, not just metadata)
        │     purpose, accountabilities, success_metrics, qualifications,
        │     reporting_context, headcount
        │
        ├── (*) RequirementSet             ← one per dimension
        │     ├── references a Library
        │     ├── (*) Requirement           ← item from that library + threshold/weight
        │     └── type-specific matching logic
        │
        └── (*) WorkActivity
              description, frequency, time_allocation
```

### Key Ideas

**Libraries are typed catalogs.** A skill library has items with proficiency levels. A psychometric library has items with scoring dimensions. A qualification library has items with validation criteria. The library type determines the structure of its items and how matching/scoring works against them.

**An org can have many libraries.** A "Technical Engineering Skills" library and a "Leadership & Management Skills" library can coexist. They might have different taxonomies, different proficiency scales, or different owners. The org-wide canonical taxonomy is just a library that happens to be comprehensive — it's not a structural constraint.

**Role profiles are multi-dimensional.** A role profile doesn't just select skills — it assembles requirement sets across multiple dimensions. Each requirement set references a library and specifies thresholds. A role might draw technical skills from one library and behavioral competencies from another.

**Role profiles are rich.** Purpose, accountabilities, success metrics, and qualifications are first-class fields — not afterthoughts stuffed into a metadata blob. A role profile should be a complete description of what the role is and what it needs.

**Gap analysis is per-dimension.** Comparing a person against a role produces a gap report per requirement set, not a single flattened score. A candidate might exceed technical skill requirements but fall short on work style fit. Each dimension uses its own scoring logic.

### Psychometric Dimension (Concrete)

We already have a psychometric model (from ds-aether) with three sub-dimensions:

- **Work Interest** (RIASEC/Holland Codes) — 6 dimensions: Realistic, Investigative, Artistic, Social, Enterprising, Conventional. Scored on a hexagonal geometry where adjacent types are compatible and opposite types are incompatible.
- **Work Style** — 16 O*NET dimensions (achievement_effort, persistence, leadership, analytical_thinking, etc.). Derived from Big Five personality via a transformation matrix.
- **Work Value** — 6 O*NET dimensions (achievement, independence, recognition, relationships, support, working_conditions). Derived from organizational culture preferences.

A role profile's psychometric requirement set might specify: "This role suits someone scoring high on Investigative + Conventional interests, with strong analytical_thinking and attention_to_detail work styles." Gap analysis for this dimension uses RIASEC similarity scoring (hexagonal distance) and threshold comparison for work styles/values.

This is just one example of a non-skill dimension. The point is that the model should accommodate it naturally rather than requiring a parallel system.

## Open Questions

1. **How typed should libraries be?** Options range from fully generic (library items are schemaless maps, type determines interpretation) to strongly typed (each library type is a separate Ecto schema). The generic approach is more flexible but harder to validate and query. The typed approach is clearer but requires new code for each dimension.

2. **Should requirement sets be typed too?** A skill requirement set needs `min_level` and `weight`. A psychometric requirement set needs target scores and tolerance ranges. These are structurally different. Should `RequirementSet` be polymorphic, or should each type be its own table?

3. **How do libraries relate to each other?** If a "Technical Skills" library and a "Data Engineering Skills" library both contain "SQL", are those the same skill or different entries? Do we need cross-library identity, or is each library fully independent?

4. **Is this over-engineered for current needs?** The immediate use case is skill-based competency frameworks. Psychometric profiles exist in a separate Rust codebase. Do we build the multi-dimensional model now, or ship the skill-only version and extend later? The risk of building now: complexity without users. The risk of waiting: baking in assumptions that make extension painful.

5. **Where does scoring/matching logic live?** Each dimension has its own matching algorithm (proficiency level comparison for skills, hexagonal distance for RIASEC, threshold comparison for work styles). Does this live in the library type definition, in the requirement set, or in a separate scoring module?

## What I'm Looking For

- Does the multi-library, multi-dimension model feel right, or is it solving a problem that doesn't exist yet?
- Is the abstraction level correct? Too abstract (premature generalization) or too concrete (will need rework)?
- Any dimensions or use cases this model doesn't handle well?
- Opinions on the open questions above.
