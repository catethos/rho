# Template Workflow

## Browse Templates
1. Call `list_frameworks(type: "industry")`
2. Present: "Available industry templates: [list with skill counts]"
3. If none exist: "No industry templates yet. Upload a framework file
   or ask Pulsifi admin to create one."

## Load Template
1. `load_framework(framework_id)` — loads into spreadsheet
2. Switch to Category view (templates usually have many roles)
3. "Loaded [template name]. You can browse, edit, and save as your company framework."

## Clone + Customize
1. Load template into spreadsheet
2. User edits (add/remove skills, change descriptions, assign roles)
3. Save as company framework: `save_framework(name, type: "company")`
4. Original template is untouched in DB

## Admin: Create Industry Template
1. Only if is_admin is true
2. User uploads file or generates framework
3. "Save as industry template? This will be visible to all companies."
4. `save_framework(name, type: "industry")`
