# Prism Design Review — Response

> Response to [prism-design-review.md](prism-design-review.md)

## The model is directionally right, but the timing is wrong

The multi-library, multi-dimension model correctly identifies the real problem: a `Framework` conflates catalog and requirement, and role profiles need more than skill selections. The Senior Data Engineer table in the doc is convincing — that's a real use case.

But the document itself names the core tension in Q4 and then doesn't resolve it. Let me work through each question.

---

## Q1: How typed should libraries be?

**Recommendation: Start generic, with a `type` discriminator + validated `metadata` map.**

The current `Skill` schema already uses `metadata: :map`. The typed approach (separate Ecto schema per library type) sounds clean but creates a proliferation problem — every new dimension needs a migration, schema, changeset, context module, plugin tool. The generic approach with `type` + `metadata` validated by a behaviour dispatch is the right middle ground:

```elixir
# Library items share a common table with type-specific validation
defmodule Prism.LibraryItem do
  schema "library_items" do
    field :type, :string    # "skill" | "psychometric" | "qualification"
    field :metadata, :map   # type-specific structure, validated by behaviour
    belongs_to :library, Prism.Library
  end
end

# Validation dispatch
defmodule Prism.LibraryItem.Validator do
  def validate(%{type: "skill"} = item), do: Prism.LibraryItem.SkillValidator.validate(item)
  def validate(%{type: "psychometric"} = item), do: ...
end
```

This keeps the schema stable while allowing type-specific validation and query logic. You can add `qualification` without a migration.

## Q2: Should requirement sets be typed too?

**Yes — but as embedded schemas within a common table, not separate tables.** A `RequirementSet` with `type` + `config` (embedded schema or validated map) is cleaner than N join tables. The matching logic already needs per-type dispatch regardless of storage — the question is just where the shape is validated.

```elixir
# requirement_sets table
field :type, :string            # "skill" | "psychometric" | "qualification"
field :config, :map             # type-specific: %{min_level: 4} vs %{target_scores: ...}
belongs_to :role_profile, RoleProfile
belongs_to :library, Library
```

## Q3: Cross-library identity?

**No cross-library identity. Libraries are independent.**

If two libraries both have "SQL", those are different items with potentially different proficiency definitions. Cross-library identity creates a coordination problem (who owns the canonical "SQL"?) without clear benefit. If you later need "these items represent the same concept", add an optional `canonical_id` or tagging system — don't bake it into the identity model.

This is consistent with the decision to allow multiple libraries per org.

## Q4: Is this over-engineered for current needs?

**Yes — but a specific subset is worth building now.** Here's the split:

**Build now** (the restructure plan already covers this):
- Multiple libraries per org (the `Library` container — this is a small schema addition)
- `RoleProfile` with rich first-class fields (purpose, accountabilities, success_metrics, qualifications)
- `RequirementSet` as the join between role profiles and libraries (replaces `RoleSkill`)

**Don't build now** (defer until psychometric integration is real):
- Library type system and type-specific validation
- Psychometric scoring logic in Elixir (it lives in Rust, leave it there)
- Generic matching/scoring dispatch

The reason: the multi-library model costs almost nothing extra — you're already splitting Framework into Library + RoleProfile, so making Library support multiple instances is trivial. The rich role profile fields are just columns. But the type system and scoring dispatch are complex and have zero users today.

## Q5: Where does scoring/matching logic live?

**In a separate scoring module, dispatched by library type.** Not in the library definition (that's data, not behavior) and not in the requirement set (that's configuration, not logic). A `Prism.Scoring` module with clauses per type:

```elixir
defmodule Prism.Scoring do
  def gap(requirement_set, candidate_data) do
    do_gap(requirement_set.type, requirement_set, candidate_data)
  end

  defp do_gap("skill", rs, data), do: Prism.Scoring.Skill.gap(rs, data)
  defp do_gap("psychometric", rs, data), do: Prism.Scoring.Psychometric.gap(rs, data)
end
```

This is cleanly extensible and testable per dimension.

---

## Dimensions this model doesn't handle well

One thing the doc glosses over: **weighting across dimensions.** A role profile assembles requirement sets from multiple libraries, but how do you produce a single "fit score" across dimensions? Is technical skill fit worth 60% and psychometric fit 20%? The model as described gives per-dimension gap reports but no mechanism for cross-dimension weighting. That's probably fine for now (per-dimension reports are more useful than a single number), but worth noting as a future design decision.

---

## Concrete recommendation

Ship the restructure plan as-is (`skill-library-restructure-plan.md`) with two additions:

1. **Change `SkillLibrary` to `Library`** with a `type` field (default `"skill"`). No validation dispatch yet — just the field.
2. **Add the rich role profile fields** (purpose, accountabilities, success_metrics, qualifications) as text columns now.

This creates the extension points without building the extension machinery. When psychometric integration becomes real, you add a `"psychometric"` library type and the scoring dispatch — but the schema is already ready.
