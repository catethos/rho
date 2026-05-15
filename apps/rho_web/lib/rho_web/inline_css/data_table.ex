defmodule RhoWeb.InlineCSS.DataTable do
  @moduledoc false

  def css do
    ~S"""
    /* === Data Table Tab Strip === */
    .dt-tab-strip {
      display: flex;
      gap: 2px;
      padding: 0 20px;
      border-bottom: 1px solid var(--border);
      background: var(--bg-deep);
    }
    .dt-tab {
      padding: 6px 14px 5px;
      font-size: 12px;
      font-weight: 500;
      color: var(--text-muted);
      background: transparent;
      border: none;
      border-bottom: 2px solid transparent;
      cursor: pointer;
      transition: color 0.15s, border-color 0.15s;
      display: inline-flex;
      align-items: center;
      gap: 6px;
    }
    .dt-tab:hover {
      color: var(--text);
    }
    .dt-tab-active {
      color: var(--text);
      border-bottom-color: var(--accent, #e07a2f);
    }
    .dt-tab-count {
      font-size: 11px;
      color: var(--text-muted);
      background: var(--bg-hover);
      padding: 1px 6px;
      border-radius: 8px;
      font-weight: 400;
    }
    .dt-tab-active .dt-tab-count {
      background: color-mix(in srgb, var(--accent, #e07a2f) 15%, transparent);
      color: var(--accent, #e07a2f);
    }

    /* === Row Selection (checkbox column + selection bar) === */
    .dt-selection-bar {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 6px 20px;
      background: color-mix(in srgb, var(--accent, #e07a2f) 8%, var(--bg-surface));
      border-bottom: 1px solid var(--border);
      font-size: 12px;
      flex-shrink: 0;
    }
    .dt-selection-count {
      color: var(--text);
      font-weight: 500;
    }
    .dt-selection-clear {
      padding: 3px 10px;
      font-size: 11px;
      font-weight: 500;
      color: var(--text-muted);
      background: var(--bg-deep);
      border: 1px solid var(--border);
      border-radius: 4px;
      cursor: pointer;
      transition: color 0.15s, border-color 0.15s, background 0.15s;
    }
    .dt-selection-clear:hover {
      color: var(--text);
      border-color: var(--accent, #e07a2f);
      background: var(--bg-hover);
    }

    .dt-th-select,
    .dt-td-select {
      width: 32px;
      padding: 0;
      text-align: center;
      vertical-align: middle;
    }
    .dt-td-select {
      cursor: pointer;
    }
    .dt-row-checkbox {
      cursor: pointer;
      width: 14px;
      height: 14px;
      margin: 0;
      accent-color: var(--accent, #e07a2f);
    }
    .dt-row-checkbox-header {
      cursor: pointer;
    }
    .dt-row-selected {
      background: color-mix(in srgb, var(--accent, #e07a2f) 6%, transparent);
      box-shadow: inset 2px 0 0 var(--accent, #e07a2f);
    }
    .dt-row-selected:hover {
      background: color-mix(in srgb, var(--accent, #e07a2f) 10%, transparent);
    }

    /* === Data Table Proficiency Panel (children_display: :panel) === */
    .dt-proficiency-row td {
      background: var(--bg-deep);
    }
    .dt-proficiency-panel {
      display: grid;
      grid-template-columns: 2.2rem 9rem 1fr 22px;
      gap: 0;
      align-items: baseline;
      padding: 0.5rem 1.25rem 0.5rem 2.5rem;
    }
    .dt-proficiency-item {
      display: contents;
    }
    .dt-proficiency-item > * {
      padding: 0.4rem 0;
      border-bottom: 1px solid var(--border);
    }
    .dt-proficiency-item:last-child > * {
      border-bottom: none;
    }
    .dt-proficiency-level {
      font-size: 0.7rem;
      font-weight: 700;
      color: var(--teal-bright);
      background: var(--teal-dim);
      padding: 0.15rem 0.4rem;
      border-radius: 4px;
      justify-self: start;
      align-self: baseline;
    }
    .dt-proficiency-name {
      font-size: 0.8rem;
      font-weight: 600;
      color: var(--text);
      padding-left: 0.5rem;
    }
    .dt-proficiency-desc {
      font-size: 0.8rem;
      color: var(--text-muted);
      line-height: 1.45;
      padding-left: 0.5rem;
    }
    .dt-col-levels {
      width: 4rem;
      text-align: center;
    }
    .dt-td.dt-col-levels {
      text-align: center;
    }

    /* === Spreadsheet Table === */
    .dt-table-wrap {
      flex: 1;
      min-height: 0;
      overflow: auto;
      padding: 16px 20px 32px;
      scroll-behavior: smooth;
    }

    .dt-table {
      width: 100%;
      border-collapse: separate;
      border-spacing: 0;
      font-size: 12.5px;
      line-height: 1.5;
    }
    .dt-th {
      background: var(--bg-deep);
      color: var(--text-muted);
      padding: 6px 14px;
      text-align: left;
      font-weight: 500;
      font-size: 10px;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      border-bottom: 2px solid var(--border);
      position: sticky;
      top: 0;
      z-index: 2;
    }
    .dt-th:first-child { border-radius: 6px 0 0 0; }
    .dt-th:last-child { border-radius: 0 6px 0 0; }

    /* Column proportions — no category/cluster since shown in group headers */
    .dt-th-id, .dt-td-id { width: 44px; text-align: center; color: var(--text-muted); font-family: 'Fragment Mono', monospace; font-size: 11px; }
    .dt-th-source, .dt-td-source { width: 24px; text-align: center; padding: 10px 4px; }
    .dt-source-badge {
      display: inline-block;
      width: 16px; height: 16px;
      line-height: 16px;
      font-size: 10px;
      font-family: 'Fragment Mono', monospace;
      font-weight: 600;
      border-radius: 3px;
      text-align: center;
      color: var(--bg-primary);
      vertical-align: middle;
    }
    .dt-source-user  { background: var(--teal); }
    .dt-source-flow  { background: var(--text-muted); }
    .dt-source-agent { background: var(--accent, #b08fff); }
    .dt-th-skill, .dt-td-skill_name { width: 18%; }
    .dt-th-desc, .dt-td-skill_description { width: 26%; }
    .dt-th-lvl, .dt-td-level { width: 44px; text-align: center; font-family: 'Fragment Mono', monospace; }
    .dt-th-lvlname, .dt-td-level_name { width: 14%; }
    .dt-th-lvldesc, .dt-td-level_description { }

    .dt-row {
      transition: background 0.12s ease;
    }
    .dt-row:hover {
      background: var(--teal-dim);
    }
    .dt-row td:first-child { border-left: 3px solid transparent; }
    .dt-row:hover td:first-child { border-left-color: var(--teal); }

    .dt-td {
      padding: 10px 14px;
      color: var(--text-primary);
      vertical-align: top;
      border-bottom: 1px solid var(--border);
      cursor: default;
    }
    .dt-td-skill_name {
      font-weight: 500;
      color: var(--text-primary);
    }
    .dt-cell-link {
      cursor: pointer;
      color: var(--teal);
      text-decoration: underline;
      text-decoration-color: transparent;
      transition: text-decoration-color 0.15s;
    }
    .dt-cell-link:hover {
      text-decoration-color: var(--teal);
    }
    .dt-td-skill_description,
    .dt-td-level_description {
      color: var(--text-secondary);
      line-height: 1.55;
      font-size: 12px;
    }
    .dt-td-level {
      font-weight: 600;
      color: var(--teal);
    }
    .dt-td-level_name {
      font-weight: 500;
    }

    /* Level badge coloring */
    .dt-row:nth-child(odd) {
      background: var(--bg-surface);
    }
    .dt-row:nth-child(even) {
      background: var(--bg-shelf);
    }
    .dt-row:hover {
      background: var(--teal-dim);
    }

    /* Streaming animation */
    @keyframes dt-flash {
      0% { background: var(--teal-glow-strong); }
      100% { background: transparent; }
    }
    .dt-row-new {
      animation: dt-flash 1s ease-out;
    }

    /* Inline editing */
    .dt-cell-input {
      width: 100%;
      background: var(--bg-surface);
      color: var(--text-primary);
      border: 1.5px solid var(--teal);
      border-radius: 4px;
      padding: 6px 8px;
      font: inherit;
      font-size: 12.5px;
      outline: none;
      box-shadow: 0 0 0 3px var(--teal-glow);
    }
    .dt-cell-input:focus {
      border-color: var(--teal-bright);
      box-shadow: 0 0 0 3px var(--teal-glow-strong);
    }
    textarea.dt-cell-input {
      min-height: 60px;
      resize: vertical;
      line-height: 1.5;
    }

    /* Empty state */
    .dt-empty {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 12px;
      padding: 80px 40px;
      color: var(--text-muted);
      font-size: 0.875rem;
    }
    .dt-empty::before {
      content: '';
      display: block;
      width: 48px;
      height: 48px;
      border-radius: 12px;
      background: var(--teal-dim);
      border: 2px dashed var(--border);
    }

    /* === Conflict Resolution Table === */
    .dt-col-confidence { width: 54px; text-align: center; }
    .dt-col-skill-a, .dt-col-skill-b { width: 18%; font-weight: 500; word-break: break-word; }
    .dt-col-desc-a, .dt-col-desc-b { color: var(--text-secondary); font-size: 12px; line-height: 1.5; word-break: break-word; }
    .dt-col-action { width: 130px; }

    .dt-action-buttons {
      display: flex;
      gap: 4px;
    }
    .dt-action-btn {
      padding: 3px 8px;
      font-size: 11px;
      font-weight: 500;
      border-radius: 4px;
      border: 1px solid var(--border);
      background: var(--bg-surface);
      color: var(--text-secondary);
      cursor: pointer;
      transition: all 0.12s ease;
      white-space: nowrap;
    }
    .dt-action-btn:hover {
      background: var(--teal-dim);
      border-color: var(--teal);
      color: var(--teal);
    }
    .dt-action-merge-a:hover, .dt-action-merge-b:hover {
      background: var(--teal-dim);
      border-color: var(--teal);
      color: var(--teal);
    }
    .dt-action-keep-both:hover {
      background: var(--amber-dim);
      border-color: var(--amber);
      color: var(--amber);
    }

    .dt-resolution-badge {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      padding: 2px 8px;
      border-radius: 4px;
      background: var(--teal-dim);
      color: var(--teal);
      font-size: 11px;
      font-weight: 500;
    }
    .dt-resolution-icon {
      font-size: 13px;
    }

    /* === Collapsible Groups === */
    .dt-group-l1 {
      margin-bottom: 12px;
      border-radius: 8px;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      overflow: hidden;
    }
    .dt-group-l1:last-child { margin-bottom: 0; }

    .dt-group { border: none; }

    .dt-group-header {
      display: flex;
      align-items: center;
      gap: 10px;
      cursor: pointer;
      user-select: none;
      list-style: none;
      transition: background 0.12s ease;
    }
    .dt-group-header::-webkit-details-marker { display: none; }
    .dt-group-header::marker { content: ''; }

    .dt-group-header-l1 {
      padding: 12px 16px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border);
      font-weight: 600;
      font-size: 0.8125rem;
      color: var(--text-primary);
    }
    .dt-group-l1.dt-collapsed > .dt-group-header-l1 {
      border-bottom-color: transparent;
    }

    .dt-group-header-l2 {
      padding: 9px 16px 9px 20px;
      background: var(--bg-shelf);
      border-bottom: 1px solid var(--border);
      font-weight: 500;
      font-size: 0.8125rem;
      color: var(--text-secondary);
    }
    .dt-group-l2.dt-collapsed:last-child > .dt-group-header-l2 {
      border-bottom-color: transparent;
    }

    .dt-group-header:hover {
      background: var(--bg-hover);
    }

    .dt-chevron {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 18px;
      height: 18px;
      border-radius: 4px;
      background: var(--bg-deep);
      flex-shrink: 0;
      transition: background 0.12s ease;
    }
    .dt-chevron::after {
      content: '';
      display: block;
      width: 0;
      height: 0;
      border-left: 4px solid var(--text-muted);
      border-top: 3px solid transparent;
      border-bottom: 3px solid transparent;
      transition: transform 0.2s ease;
    }
    .dt-group:not(.dt-collapsed) > .dt-group-header .dt-chevron::after {
      transform: rotate(90deg);
    }
    .dt-group-header:hover .dt-chevron {
      background: var(--border);
    }

    .dt-group-name {
      flex: 1;
    }
    .dt-group-header-l1 .dt-group-name {
      letter-spacing: 0.01em;
    }

    .dt-group-count {
      font-size: 11px;
      color: var(--text-muted);
      font-weight: 400;
      font-family: 'Fragment Mono', monospace;
      padding: 2px 8px;
      background: var(--bg-deep);
      border-radius: 10px;
    }

    .dt-group-content {
      transition: none;
    }
    .dt-hidden {
      display: none;
    }

    .dt-group-l2 .dt-table {
      margin: 0;
    }
    .dt-group-l2:last-child .dt-table tr:last-child td {
      border-bottom: none;
    }

    /* === Toolbar Actions === */
    .dt-toolbar-actions {
      display: flex;
      align-items: center;
      gap: 6px;
      margin-left: auto;
    }

    .dt-action-btn {
      padding: 4px 12px;
      font-size: 11px;
      font-weight: 500;
      border-radius: 4px;
      border: 1px solid var(--border);
      background: var(--bg-surface);
      color: var(--text-secondary);
      cursor: pointer;
      transition: all 0.12s ease;
    }
    .dt-action-btn:hover {
      background: var(--bg-hover);
      border-color: var(--text-muted);
      color: var(--text-primary);
    }
    .dt-save-btn:hover {
      background: var(--teal-dim);
      border-color: var(--teal);
      color: var(--teal);
    }
    .dt-publish-btn:hover {
      background: var(--green-dim, rgba(63, 185, 80, 0.1));
      border-color: var(--green, #3fb950);
      color: var(--green, #3fb950);
    }
    .dt-fork-btn:hover {
      background: var(--blue-dim, rgba(56, 139, 253, 0.1));
      border-color: var(--blue, #388bfd);
      color: var(--blue, #388bfd);
    }
    .dt-suggest-btn:hover {
      background: var(--orange-dim, rgba(219, 109, 40, 0.1));
      border-color: var(--orange, #db6d28);
      color: var(--orange, #db6d28);
    }
    .dt-export-btn:hover {
      background: var(--purple-dim, rgba(163, 113, 247, 0.1));
      border-color: var(--purple, #a371f7);
      color: var(--purple, #a371f7);
    }
    .dt-export-dropdown {
      position: relative;
      display: inline-block;
    }
    .dt-export-menu {
      display: none;
      position: absolute;
      top: 100%;
      right: 0;
      margin-top: 4px;
      min-width: 140px;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: 6px;
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.08);
      z-index: 100;
      overflow: hidden;
    }
    .dt-export-menu-open {
      display: flex;
      flex-direction: column;
    }
    .dt-export-option {
      padding: 8px 12px;
      font-size: 12px;
      color: var(--text-secondary);
      background: none;
      border: none;
      text-align: left;
      cursor: pointer;
      transition: background 0.1s ease;
    }
    .dt-export-option:hover {
      background: var(--bg-hover);
      color: var(--text-primary);
    }
    .dt-export-option + .dt-export-option {
      border-top: 1px solid var(--border);
    }

    .dt-flash {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 4px 10px;
      font-size: 12px;
      font-weight: 500;
      color: var(--orange, #db6d28);
      background: var(--orange-dim, rgba(219, 109, 40, 0.12));
      border: 1px solid var(--orange, #db6d28);
      border-radius: 999px;
      max-width: 60ch;
      animation: dt-flash-fade 12s ease-out forwards;
    }
    .dt-flash-text {
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .dt-flash-close {
      background: none;
      border: none;
      color: inherit;
      font-size: 14px;
      line-height: 1;
      cursor: pointer;
      padding: 0;
      opacity: 0.6;
    }
    .dt-flash-close:hover {
      opacity: 1;
    }
    @keyframes dt-flash-fade {
      0% { opacity: 0; transform: translateY(-4px); }
      6% { opacity: 1; transform: translateY(0); }
      90% { opacity: 1; transform: translateY(0); }
      100% { opacity: 0; transform: translateY(0); }
    }

    /* === Action Dialogs === */
    .dt-dialog-backdrop {
      position: absolute;
      inset: 0;
      background: rgba(0, 0, 0, 0.4);
      display: flex;
      align-items: flex-start;
      justify-content: center;
      padding-top: 80px;
      z-index: 100;
    }
    .dt-dialog {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 20px 24px;
      width: 380px;
      box-shadow: 0 8px 32px rgba(0, 0, 0, 0.3);
    }
    .dt-dialog-title {
      font-size: 14px;
      font-weight: 600;
      color: var(--text-primary);
      margin: 0 0 16px;
    }
    .dt-dialog-label {
      display: block;
      font-size: 11px;
      font-weight: 500;
      color: var(--text-secondary);
      margin-bottom: 4px;
      margin-top: 12px;
    }
    .dt-dialog-label:first-of-type { margin-top: 0; }
    .dt-dialog-hint {
      color: var(--text-muted);
      font-weight: 400;
    }
    .dt-dialog-input {
      width: 100%;
      padding: 6px 10px;
      font-size: 13px;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: var(--bg-deep);
      color: var(--text-primary);
      outline: none;
      box-sizing: border-box;
    }
    .dt-dialog-input:focus {
      border-color: var(--teal, #2dd4bf);
    }
    .dt-dialog-actions {
      display: flex;
      justify-content: flex-end;
      gap: 8px;
      margin-top: 20px;
    }
    .dt-dialog-btn {
      padding: 6px 16px;
      font-size: 12px;
      font-weight: 500;
      border-radius: 4px;
      border: 1px solid var(--border);
      cursor: pointer;
      transition: all 0.12s ease;
    }
    .dt-dialog-cancel {
      background: var(--bg-surface);
      color: var(--text-secondary);
    }
    .dt-dialog-cancel:hover {
      background: var(--bg-hover);
    }
    .dt-dialog-confirm {
      background: var(--bg-surface);
      color: var(--text-primary);
    }
    .dt-dialog-confirm.dt-save-btn:hover {
      background: var(--teal-dim);
      border-color: var(--teal);
      color: var(--teal);
    }
    .dt-dialog-confirm.dt-publish-btn:hover {
      background: var(--green-dim, rgba(63, 185, 80, 0.1));
      border-color: var(--green, #3fb950);
      color: var(--green, #3fb950);
    }
    .dt-dialog-confirm.dt-suggest-btn:hover {
      background: var(--orange-dim, rgba(219, 109, 40, 0.1));
      border-color: var(--orange, #db6d28);
      color: var(--orange, #db6d28);
    }

    /* === Add Row Buttons === */
    .dt-add-row-btn {
      padding: 4px 12px;
      font-size: 11px;
      font-weight: 500;
      border-radius: 4px;
      border: 1px solid var(--border);
      background: var(--bg-surface);
      color: var(--text-secondary);
      cursor: pointer;
      transition: all 0.12s ease;
    }
    .dt-add-row-btn:hover {
      background: var(--teal-dim);
      border-color: var(--teal);
      color: var(--teal);
    }
    .dt-add-row-inline {
      display: block;
      width: 100%;
      padding: 6px 16px;
      font-size: 11px;
      font-weight: 500;
      color: var(--text-muted);
      background: transparent;
      border: none;
      border-top: 1px dashed var(--border);
      cursor: pointer;
      text-align: left;
      transition: color 0.12s, background 0.12s;
    }
    .dt-add-row-inline:hover {
      color: var(--teal);
      background: var(--teal-dim);
    }
    .dt-group-add-row {
      /* wrapper, no extra styles needed */
    }

    /* === Delete Row Buttons === */
    .dt-th-actions {
      width: 36px;
    }
    .dt-td-row-actions {
      width: 36px;
      text-align: center;
      padding: 0 4px !important;
      vertical-align: middle;
    }
    .dt-row-delete-btn {
      display: none;
      width: 22px;
      height: 22px;
      font-size: 14px;
      line-height: 1;
      border-radius: 4px;
      border: none;
      background: transparent;
      color: var(--text-muted);
      cursor: pointer;
      transition: all 0.12s ease;
    }
    .dt-row:hover .dt-row-delete-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
    }
    .dt-row-delete-btn:hover {
      background: var(--red-dim, rgba(220, 80, 80, 0.15));
      color: var(--red, #dc5050);
    }
    .dt-delete-confirm {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      font-size: 10px;
      white-space: nowrap;
    }
    .dt-delete-confirm-text {
      color: var(--red, #dc5050);
      font-weight: 500;
    }
    .dt-delete-yes, .dt-delete-no {
      padding: 1px 6px;
      font-size: 10px;
      font-weight: 500;
      border-radius: 3px;
      border: 1px solid var(--border);
      background: var(--bg-surface);
      color: var(--text-secondary);
      cursor: pointer;
    }
    .dt-delete-yes:hover {
      background: var(--red-dim, rgba(220, 80, 80, 0.15));
      border-color: var(--red, #dc5050);
      color: var(--red, #dc5050);
    }
    .dt-delete-no:hover {
      background: var(--bg-hover);
    }

    /* === Sort Indicator === */
    .dt-sort-indicator {
      font-size: 8px;
      margin-left: 3px;
      color: var(--teal);
    }
    .dt-th-sorted {
      color: var(--teal) !important;
    }

    /* === Add/Delete Child (Proficiency) Buttons === */
    .dt-proficiency-add {
      padding: 0 1.25rem 0.5rem 2.5rem;
    }
    .dt-add-child-btn {
      padding: 3px 10px;
      font-size: 11px;
      font-weight: 500;
      border-radius: 4px;
      border: 1px dashed var(--border);
      background: transparent;
      color: var(--text-muted);
      cursor: pointer;
      transition: all 0.12s ease;
    }
    .dt-add-child-btn:hover {
      border-color: var(--teal);
      color: var(--teal);
      background: var(--teal-dim);
    }
    .dt-child-delete-btn {
      visibility: hidden;
      display: inline-flex;
      width: 18px;
      height: 18px;
      font-size: 13px;
      line-height: 1;
      border-radius: 3px;
      border: none;
      background: transparent;
      color: var(--text-muted);
      cursor: pointer;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
      align-self: center;
      transition: all 0.12s ease;
    }
    .dt-proficiency-item:hover .dt-child-delete-btn,
    .dt-child-row:hover .dt-child-delete-btn {
      visibility: visible;
    }
    .dt-child-delete-btn:hover {
      background: var(--red-dim, rgba(220, 80, 80, 0.15));
      color: var(--red, #dc5050);
    }

    /* === Editable hints (click-to-edit text) === */
    .dt-editable-hint {
      cursor: text;
      border-bottom: 1px dashed transparent;
      transition: border-color 0.15s;
    }
    .dt-editable-hint:hover {
      border-bottom-color: var(--text-muted);
    }
    .dt-inline-input {
      font: inherit;
      padding: 2px 6px;
    }
    textarea.dt-inline-textarea {
      width: 100%;
      min-height: 3.5rem;
      resize: none;
      overflow: hidden;
      line-height: 1.45;
      box-sizing: border-box;
    }

    /* === Group header editing === */
    .dt-group-edit-form {
      flex: 1;
      display: inline;
    }
    .dt-group-edit-input {
      font-size: inherit;
      font-weight: inherit;
      padding: 2px 8px;
      width: 100%;
      max-width: 300px;
    }
    .dt-chevron {
      cursor: pointer;
    }
    .dt-group-count {
      cursor: pointer;
    }
    .dt-group-add-btn {
      display: none;
      width: 22px;
      height: 22px;
      font-size: 14px;
      font-weight: 600;
      line-height: 1;
      border-radius: 4px;
      border: 1px solid var(--border);
      background: var(--bg-deep);
      color: var(--text-muted);
      cursor: pointer;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
      transition: all 0.12s ease;
    }
    .dt-group-header:hover .dt-group-add-btn {
      display: inline-flex;
    }
    .dt-group-add-btn:hover {
      background: var(--teal-dim);
      border-color: var(--teal);
      color: var(--teal);
    }

    /* Spreadsheet chat panel — always mounted, visibility via classes */
    .dt-chat-panel {
      width: 100%;
      border-left: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      min-height: 0;
      overflow: hidden;
      background: var(--bg-surface);
    }

    /* Full-width chat when no workspaces */
    .session-layout:not(.workspace-mode) .dt-chat-panel {
      max-width: 1180px;
      margin: 0 auto;
      border-left: none;
    }
    .dt-chat-panel.is-collapsed {
      width: 0;
      min-width: 0;
      opacity: 0;
      border-left: none;
      pointer-events: none;
    }
    .dt-chat-panel.is-hidden {
      display: none;
    }

    .dt-chat-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 1rem;
      padding: 10px 16px;
      border-bottom: 1px solid var(--border);
      height: 48px;
      flex-shrink: 0;
    }

    .dt-chat-context {
      display: flex;
      align-items: center;
      min-width: 0;
      gap: 8px;
    }

    .dt-chat-title {
      font-size: 0.875rem;
      font-weight: 600;
      color: var(--text-primary);
    }
    .chat-active-agent {
      max-width: 14rem;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      padding: 0.16rem 0.5rem;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: var(--bg-shelf);
      color: var(--text-secondary);
      font-size: 0.68rem;
      font-weight: 650;
      letter-spacing: 0;
    }
    .chat-session-id {
      max-width: 8.5rem;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      color: var(--text-muted);
      font-family: var(--font-mono);
      font-size: 0.68rem;
    }

    @media (max-width: 960px) {
      .dt-chat-header {
        min-height: 48px;
        height: auto;
        flex-wrap: wrap;
      }
      .session-controls {
        width: 100%;
        justify-content: flex-start;
        margin-left: 0;
      }
    }

    @media (max-width: 720px) {
      .session-controls .header-tokens,
      .session-controls .header-cost {
        display: none;
      }
      .chat-active-agent {
        max-width: 8rem;
      }
    }

    .dt-chat-panel .chat-feed {
      flex: 1;
      overflow-y: auto;
    }

    .dt-chat-panel .chat-input-area {
      border-top: 1px solid var(--border);
    }

    .workbench-suggestion-strip {
      display: flex;
      gap: 0.4rem;
      padding: 0.55rem 0.75rem 0;
      overflow-x: auto;
    }
    .workbench-suggestion-chip {
      flex: 0 0 auto;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: var(--bg-shelf);
      color: var(--text-secondary);
      cursor: pointer;
      font-size: 0.74rem;
      font-weight: 600;
      padding: 0.32rem 0.62rem;
      transition: color 0.15s, border-color 0.15s, background 0.15s;
    }
    .workbench-suggestion-chip:hover {
      color: var(--text-primary);
      border-color: var(--teal);
      background: color-mix(in srgb, var(--teal) 10%, var(--bg-surface));
    }

    /* Streaming indicator on toolbar */
    .dt-streaming {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      font-size: 11px;
      color: var(--teal);
      font-family: 'Fragment Mono', monospace;
      padding: 3px 10px;
      background: var(--teal-dim);
      border-radius: 10px;
    }

    .dt-streaming::before {
      content: '';
      display: inline-block;
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: var(--teal);
      animation: pulse-dot 1.2s ease-in-out infinite;
    }

    @keyframes pulse-dot {
      0%, 100% { opacity: 1; transform: scale(1); }
      50% { opacity: 0.3; transform: scale(0.8); }
    }

    /* === Chatroom workspace === */
    .chatroom-workspace {
      display: flex;
      flex-direction: column;
      height: 100%;
      min-height: 0;
      background: var(--bg-base);
    }
    .chatroom-workspace.hidden { display: none; }
    .chatroom-timeline {
      flex: 1;
      overflow-y: auto;
      padding: 1.5rem;
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
    }
    .chatroom-empty {
      color: var(--text-muted);
      font-size: 0.9rem;
      text-align: center;
      padding-top: 3rem;
    }
    .chatroom-msg {
      padding: 0.5rem 0.75rem;
      border-radius: 8px;
      background: var(--bg-surface);
      border: 1px solid var(--border);
    }
    .chatroom-msg-streaming {
      border-color: var(--teal-dim);
    }
    .chatroom-msg-header {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      margin-bottom: 0.25rem;
    }
    .chatroom-speaker {
      font-weight: 600;
      font-size: 0.825rem;
    }
    .chatroom-direction {
      font-size: 0.75rem;
      color: var(--text-muted);
    }
    .chatroom-typing {
      color: var(--teal);
      animation: pulse 1.2s ease-in-out infinite;
    }
    .chatroom-timestamp {
      font-size: 0.7rem;
      color: var(--text-muted);
      margin-left: auto;
      font-family: 'Fragment Mono', monospace;
    }
    .chatroom-msg-body {
      font-size: 0.875rem;
      color: var(--text-primary);
      line-height: 1.5;
      white-space: pre-wrap;
    }
    .chatroom-streaming-text {
      color: var(--text-secondary);
    }
    .chatroom-input-area {
      padding: 0.75rem 1rem;
      border-top: 1px solid var(--border);
      background: var(--bg-surface);
      flex-shrink: 0;
    }
    .chatroom-input-form {
      display: flex;
      gap: 0.5rem;
    }
    .chatroom-input {
      flex: 1;
      padding: 0.5rem 0.75rem;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--bg-base);
      color: var(--text-primary);
      font-size: 0.85rem;
      outline: none;
      transition: border-color 0.15s;
    }
    .chatroom-input:focus {
      border-color: var(--teal);
    }
    .chatroom-send-btn {
      padding: 0.5rem 1rem;
      border: none;
      border-radius: 6px;
      background: var(--teal);
      color: #fff;
      font-size: 0.825rem;
      font-weight: 500;
      cursor: pointer;
      transition: opacity 0.15s;
    }
    .chatroom-send-btn:hover { opacity: 0.85; }

    """
  end
end
