# Import Framework from File

## Step 1: Review File Summary

The upload summary in the message tells you: filename, row count, column names, sample rows, and file path.
Read this first to understand what was uploaded.

## Step 2: Choose Extraction Strategy

**Simple files** (clean CSV, small Excel ≤20 columns with obvious headers):
- Use `get_uploaded_file(filename)` to read parsed data directly
- Proceed to Step 3 (Column Mapping)

**Complex files** (multi-sheet Excel, mapping matrices, 50+ columns, merged headers):
- Proceed to Step 2b (Confirm + Delegate)

### Step 2b: Confirm with User, then Delegate

**BEFORE delegating, tell the user what you found and ask for confirmation:**

"I can see this is a [describe file type] with [X sheets, Y rows, Z columns].
It looks like [describe structure — e.g., 'a skill-role mapping matrix with proficiency levels'].
I estimate about [N] rows after extraction. Shall I proceed with the extraction?"

**WAIT for user to say yes.**

After user approves, call `delegate_task` with:
- role: `"data_extractor"`
- task: **First line MUST be the EXACT file path from the upload summary.** Look for "File path:" in the upload summary and copy it verbatim — do NOT use an example or placeholder path.

The rest of the task should describe the file structure briefly.

- inherit_context: false

Then call `await_task` to wait for completion.

After the extractor finishes:
1. Call `get_table_summary` to verify what was imported
2. Report the results to the user
3. **Do NOT call `add_rows` yourself** — the extractor already loaded all the data
4. Remind user to save

## Step 3: Column Mapping (for simple/direct import only)

Map the uploaded columns to spreadsheet columns. Propose the mapping and confirm with the user.

**Spreadsheet columns:** role, category, cluster, skill_name, skill_description, level, level_name, level_description

If columns don't map cleanly, explain what you found and ask the user how to proceed.

## Step 4: Confirm Before Importing (simple import only)

Present the mapping summary and wait for user confirmation.

## Step 5: Import (simple import only)

Call `add_rows` directly with mapped data. Batch into groups of 50 rows.

## Step 6: Report

Report what was imported: row count, categories found, roles found.

Remind user to save:
"Imported [N] rows. Save as [company/industry] framework?"
