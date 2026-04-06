# De-duplication Workflow

Before generating skills for a role, check for existing data:

## Detection
1. Call `list_frameworks(type: "company")` to check own company frameworks
2. Check if any framework's `roles` array contains the requested role name
3. If found: proceed to resolution. If not: proceed with generation.

## Case 1: Same skill, same definition, different roles
- Both roles define "Communication" the same way
- Action: one entry in library, both roles reference it
- Agent: "Communication already exists for Data Analyst. I'll reuse the same
  definition for Project Manager. The required proficiency level can differ."

## Case 2: Same skill name, different definitions
- "Python" for DA = analytics, for DE = distributed systems
- Agent asks: "Both roles need 'Python' but with different focus:
  a) Keep one generic definition
  b) Create two variants: 'Python (Analytics)' and 'Python (Engineering)'
  c) Keep the first, adjust the second"
- User decides

## Case 3: Same role created again (user forgot)
- Agent found existing framework with matching role
- Agent: "I found an existing framework '[name]' from [date] with [N] skills
  for [role]. Do you want to:
  - Load and update it
  - Start fresh (create new)
  - Compare: generate new alongside old"
- User decides → agent loads existing or generates new

## Case 4: Industry template + company customization
- Company loaded AICB template and edited it
- Original AICB preserved as industry template
- Company version saved separately
- If user loads AICB again, they get the original (not their edits)
- Agent: "You have a customized version. Load your version or the original template?"
