---
name: create-framework
description: Route create-framework requests into the chat-hosted flow; provide fallback context for edge cases outside an active flow.
uses: [manage_role, analyze_role, load_similar_roles, generate_framework_taxonomy, generate_skills_for_taxonomy, generate_proficiency, save_framework, seed_framework_from_roles, browse_library, manage_library]
---

# Create Framework

Create-framework is primarily owned by the chat-hosted `create-framework` flow.
When the user asks to create, build, or make a skill framework, prefer starting
or continuing that flow instead of running a tool playbook from this skill.

The flow owns:

- starting point selection: similar role, scratch, extend existing, or merge
- deterministic node routing
- taxonomy and skill review gates
- Workbench table focus
- save timing

Use this skill only as fallback guidance when no active flow is available and
the request cannot be routed by the web shell.

## Fallback Rules

- Do not fake flow progress as user-authored chat messages.
- Do not let the LLM choose global workflow branches when a flow card is active.
- If a Workbench table already exists, use the table name the user is reviewing.
- `taxonomy:<name>` is the taxonomy review table.
- `library:<name>` is the generated skill draft table.
- `save_framework` is the persistence boundary; do not create an empty library
  first.
- Proficiency generation requires explicit user approval after skill review.

## Tool Fallback

If you must operate outside the flow, keep the sequence narrow:

1. Ask only for missing essentials: name, description, domain or target roles.
2. Generate taxonomy with `generate_framework_taxonomy`.
3. Stop and ask the user to review the taxonomy table.
4. After approval, call `generate_skills_for_taxonomy`.
5. After skill review, ask before `generate_proficiency`.
6. Save only when the user explicitly asks to save.

For exact role-profile cloning, resolve the source roles first and use
`seed_framework_from_roles`; do not regenerate skills when the user asked for a
literal copy.
