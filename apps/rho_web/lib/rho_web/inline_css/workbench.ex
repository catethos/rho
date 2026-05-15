defmodule RhoWeb.InlineCSS.Workbench do
  @moduledoc false

  def css do
    ~S"""
    /* === Spreadsheet Layout === */
    .dt-layout {
      display: flex;
      height: calc(100vh - var(--nav-height));
      overflow: hidden;
      background: var(--bg-abyss);
    }

    .dt-panel {
      flex: 1;
      min-width: 0;
      min-height: 0;
      display: flex;
      flex-direction: column;
      position: relative;
      overflow: hidden;
    }
    .dt-panel.hidden { display: none; }

    .workbench-home {
      flex: 1;
      min-height: 0;
      display: flex;
      flex-direction: column;
      justify-content: center;
      padding: 32px;
      overflow: auto;
      background:
        linear-gradient(90deg, rgba(224, 122, 47, 0.07), transparent 32%),
        repeating-linear-gradient(0deg, rgba(40, 35, 28, 0.028) 0, rgba(40, 35, 28, 0.028) 1px, transparent 1px, transparent 30px),
        var(--bg-abyss);
    }

    .workbench-home-shell {
      width: min(1180px, 100%);
      margin: 0 auto;
      display: grid;
      gap: 18px;
    }

    .workbench-home-hero {
      display: block;
    }

    .workbench-home-kicker,
    .workbench-modal-kicker {
      margin: 0 0 6px;
      color: var(--accent, #e07a2f);
      font-size: 11px;
      line-height: 1.2;
      font-weight: 800;
      text-transform: uppercase;
      letter-spacing: 0;
    }

    .workbench-home h2 {
      margin: 0;
      color: var(--text-primary);
      font-size: clamp(2rem, 3vw, 3.3rem);
      line-height: 0.98;
      font-weight: 780;
      max-width: 820px;
    }

    .workbench-home-lede {
      max-width: 720px;
      margin: 14px 0 0;
      color: var(--text-secondary);
      font-size: 0.98rem;
      line-height: 1.55;
    }

    .workbench-utility-row {
      display: flex;
      align-items: center;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 18px;
    }

    .workbench-agent-state {
      display: inline-flex;
      align-items: center;
      gap: 9px;
      max-width: 680px;
      padding: 8px 10px;
      border: 1px solid var(--border);
      border-radius: 7px;
      background: color-mix(in srgb, var(--bg-surface) 78%, transparent);
      color: var(--text-secondary);
      font-size: 0.84rem;
      line-height: 1.35;
    }

    .workbench-agent-state strong {
      color: var(--text-primary);
      font-weight: 720;
    }

    .workbench-state-dot {
      width: 8px;
      height: 8px;
      flex: 0 0 auto;
      border-radius: 50%;
      background: #d8a061;
      box-shadow: 0 0 0 3px rgba(216, 160, 97, 0.14);
    }

    .workbench-state-dot.is-ready {
      background: #4e9b72;
      box-shadow: 0 0 0 3px rgba(78, 155, 114, 0.16);
    }

    .workbench-state-dot.is-open {
      background: var(--accent, #e07a2f);
      box-shadow: 0 0 0 3px rgba(224, 122, 47, 0.14);
    }

    .workbench-return-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 34px;
      width: fit-content;
      margin-top: 12px;
      padding: 0 12px;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--bg-surface);
      color: var(--text-primary);
      cursor: pointer;
      font-size: 0.82rem;
      font-weight: 700;
      transition: border-color 120ms ease, transform 120ms ease;
    }

    .workbench-return-btn:hover {
      border-color: var(--accent, #e07a2f);
      transform: translateY(-1px);
    }

    .workbench-library-source-btn.is-disabled {
      cursor: not-allowed;
      opacity: 0.62;
      filter: saturate(0.62);
    }

    .workbench-status-panel {
      padding: 18px 20px 20px;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: color-mix(in srgb, var(--bg-surface) 88%, transparent);
      box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.34);
    }

    .workbench-status-header {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 12px;
    }

    .workbench-status-header h3 {
      margin: 0;
      color: var(--text-primary);
      font-size: 1rem;
      line-height: 1.2;
      font-weight: 760;
    }

    .workbench-status-title {
      min-width: 0;
    }

    .workbench-title-row {
      display: flex;
      align-items: center;
      gap: 9px;
    }

    .workbench-status-metrics {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      justify-content: flex-end;
      color: var(--text-secondary);
      font-size: 0.78rem;
    }

    .workbench-status-metrics span {
      display: inline-flex;
      align-items: baseline;
      gap: 4px;
      min-height: 28px;
      padding: 0 9px;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: var(--bg-abyss);
    }

    .workbench-status-metrics strong {
      color: var(--text-primary);
      font-weight: 780;
    }

    .workbench-library-create-menu {
      position: relative;
      flex: 0 0 auto;
    }

    .workbench-library-create-menu summary {
      width: 24px;
      height: 24px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      border: 1px solid color-mix(in srgb, var(--accent, #e07a2f) 38%, var(--border));
      border-radius: 50%;
      background: color-mix(in srgb, var(--bg-surface) 70%, transparent);
      color: var(--accent, #e07a2f);
      cursor: pointer;
      font-size: 0.92rem;
      line-height: 1;
      font-weight: 820;
      list-style: none;
      transform: translateY(1px);
      transition: border-color 120ms ease, background 120ms ease, color 120ms ease, transform 120ms ease;
    }

    .workbench-library-create-menu summary::-webkit-details-marker {
      display: none;
    }

    .workbench-library-create-menu summary:hover,
    .workbench-library-create-menu[open] summary {
      border-color: var(--accent, #e07a2f);
      background: color-mix(in srgb, var(--accent, #e07a2f) 10%, var(--bg-surface));
      color: var(--text-primary);
      transform: translateY(0);
    }

    .workbench-library-create-popover {
      position: absolute;
      top: calc(100% + 8px);
      left: 0;
      z-index: 20;
      width: 210px;
      display: grid;
      gap: 2px;
      padding: 5px;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--bg-surface);
      box-shadow: 0 14px 30px rgba(30, 24, 18, 0.14);
    }

    .workbench-library-source-btn {
      min-width: 0;
      min-height: 32px;
      display: flex;
      align-items: center;
      justify-content: flex-start;
      padding: 0 9px;
      border: 0;
      border-radius: 6px;
      background: transparent;
      color: var(--text-primary);
      cursor: pointer;
      text-align: left;
      transition: background 120ms ease, color 120ms ease;
    }

    .workbench-library-source-btn:hover {
      background: color-mix(in srgb, var(--accent, #e07a2f) 10%, transparent);
    }

    .workbench-library-source-btn span {
      min-width: 0;
      overflow: hidden;
      color: var(--text-secondary);
      font-size: 0.78rem;
      font-weight: 660;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .workbench-library-source-btn:hover span {
      color: var(--text-primary);
    }

    .workbench-library-list {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 8px;
      max-height: 360px;
      overflow: auto;
      padding-right: 4px;
    }

    .workbench-library-row {
      min-width: 0;
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 10px;
      align-items: center;
      min-height: 48px;
      padding: 8px 10px;
      border: 1px solid color-mix(in srgb, var(--border) 72%, transparent);
      border-radius: 7px;
      background: color-mix(in srgb, var(--bg-surface) 66%, transparent);
      color: inherit;
      cursor: pointer;
      text-align: left;
      transition: border-color 120ms ease, background 120ms ease, transform 120ms ease;
    }

    .workbench-library-row:hover {
      border-color: color-mix(in srgb, var(--accent, #e07a2f) 58%, var(--border));
      background: var(--bg-surface);
      transform: translateY(-1px);
    }

    .workbench-library-main {
      min-width: 0;
      display: grid;
      gap: 3px;
    }

    .workbench-library-name {
      min-width: 0;
      overflow: hidden;
      color: var(--text-primary);
      font-size: 0.85rem;
      font-weight: 680;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .workbench-library-open {
      min-height: 26px;
      display: inline-flex;
      align-items: center;
      padding: 0 9px;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: var(--bg-abyss);
      color: var(--text-secondary);
      font-size: 0.7rem;
      font-weight: 760;
    }

    .workbench-library-row:hover .workbench-library-open {
      border-color: color-mix(in srgb, var(--accent, #e07a2f) 48%, var(--border));
      color: var(--text-primary);
    }

    .workbench-library-meta,
    .workbench-empty-note {
      color: var(--text-secondary);
      font-size: 0.78rem;
      line-height: 1.35;
    }

    .workbench-empty-note {
      margin: 0;
    }

    .workbench-chat-toggle {
      min-height: 34px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      padding: 0 12px;
      border: 1px solid color-mix(in srgb, var(--border) 82%, transparent);
      border-radius: 6px;
      background: color-mix(in srgb, var(--bg-surface) 70%, transparent);
      color: var(--text-secondary);
      cursor: pointer;
      font-size: 0.78rem;
      font-weight: 700;
      transition: border-color 120ms ease, color 120ms ease, background 120ms ease;
    }

    .workbench-chat-toggle:hover {
      border-color: var(--accent, #e07a2f);
      background: var(--bg-surface);
      color: var(--text-primary);
    }

    @media (max-width: 980px) {
      .workbench-home {
        justify-content: flex-start;
        padding: 22px;
      }

      .workbench-home-hero {
        grid-template-columns: 1fr;
      }

      .workbench-library-list {
        grid-template-columns: 1fr;
        max-height: none;
      }

      .workbench-status-header,
      .workbench-library-row {
        grid-template-columns: 1fr;
      }

      .workbench-library-create-popover {
        left: 0;
        right: auto;
      }

      .workbench-library-open {
        display: none;
      }

      .workbench-status-header {
        display: grid;
      }

      .workbench-status-metrics {
        justify-content: flex-start;
      }

    }

    .workbench-modal-backdrop {
      position: fixed;
      inset: 0;
      z-index: 1100;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 24px;
      background: rgba(8, 12, 18, 0.58);
    }

    .workbench-modal {
      width: min(620px, 100%);
      max-height: min(760px, calc(100vh - 48px));
      overflow: auto;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      box-shadow: 0 24px 70px rgba(0, 0, 0, 0.32);
    }

    .workbench-modal-header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 18px;
      padding: 22px 22px 14px;
      border-bottom: 1px solid var(--border);
    }

    .workbench-modal-header h3 {
      margin: 0;
      color: var(--text-primary);
      font-size: 1.15rem;
      line-height: 1.2;
    }

    .workbench-modal-header p:last-child {
      margin: 7px 0 0;
      color: var(--text-secondary);
      font-size: 0.9rem;
      line-height: 1.4;
    }

    .workbench-modal-close {
      width: 32px;
      height: 32px;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: transparent;
      color: var(--text-secondary);
      cursor: pointer;
      font-size: 20px;
      line-height: 1;
    }

    .workbench-modal-form {
      display: grid;
      gap: 14px;
      padding: 18px 22px 22px;
    }

    .workbench-field {
      display: grid;
      gap: 6px;
      color: var(--text-secondary);
      font-size: 0.78rem;
      font-weight: 650;
    }

    .workbench-field input,
    .workbench-field textarea,
    .workbench-field select {
      width: 100%;
      min-height: 38px;
      padding: 9px 10px;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--bg-abyss);
      color: var(--text-primary);
      font: inherit;
      font-weight: 500;
    }

    .workbench-field textarea {
      resize: vertical;
      line-height: 1.45;
    }

    .workbench-file-picker {
      display: grid;
      grid-template-columns: auto minmax(0, 1fr);
      align-items: center;
      gap: 10px;
      min-height: 42px;
      padding: 8px 10px;
      border: 1px dashed var(--border);
      border-radius: 6px;
      background: var(--bg-abyss);
    }

    .workbench-file-button {
      display: inline-flex;
      align-items: center;
      min-height: 28px;
      padding: 0 12px;
      border: 1px solid var(--border);
      border-radius: 5px;
      background: var(--bg-subtle);
      color: var(--text-primary);
      cursor: pointer;
      font-size: 0.82rem;
      font-weight: 650;
      white-space: nowrap;
    }

    .workbench-file-summary {
      min-width: 0;
      overflow: hidden;
      color: var(--text-primary);
      font-size: 0.82rem;
      font-weight: 550;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .workbench-modal-error {
      margin: 16px 22px 0;
      padding: 10px 12px;
      border: 1px solid rgba(212, 88, 88, 0.35);
      border-radius: 6px;
      background: rgba(212, 88, 88, 0.1);
      color: #f0aaaa;
      font-size: 0.86rem;
    }

    .workbench-modal-actions {
      display: flex;
      align-items: center;
      justify-content: flex-end;
      gap: 10px;
      margin-top: 4px;
    }

    .workbench-btn-primary,
    .workbench-btn-secondary,
    .workbench-secondary-link {
      min-height: 38px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      padding: 0 14px;
      border-radius: 6px;
      font-size: 0.86rem;
      font-weight: 700;
      text-decoration: none;
      cursor: pointer;
    }

    .workbench-btn-primary {
      border: 1px solid var(--accent, #e07a2f);
      background: var(--accent, #e07a2f);
      color: #111;
    }

    .workbench-btn-primary:disabled {
      opacity: 0.62;
      cursor: wait;
    }

    .workbench-btn-secondary,
    .workbench-secondary-link {
      border: 1px solid var(--border);
      background: transparent;
      color: var(--text-secondary);
    }

    .dt-toolbar,
    .dt-artifact-header {
      display: flex;
      align-items: center;
      gap: 14px;
      padding: 14px 20px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border);
      min-height: 86px;
      flex-shrink: 0;
    }

    .dt-actions-hub-btn {
      border-color: color-mix(in srgb, var(--accent, #e07a2f) 54%, var(--border));
      color: var(--text-primary);
    }

    .dt-artifact-main {
      min-width: 0;
      display: flex;
      flex-direction: column;
      gap: 5px;
    }

    .dt-artifact-kicker {
      font-size: 10px;
      font-weight: 700;
      text-transform: uppercase;
      color: var(--accent, #e07a2f);
      letter-spacing: 0;
    }

    .dt-title {
      margin: 0;
      font-size: 1.125rem;
      line-height: 1.15;
      font-weight: 700;
      color: var(--text-primary);
      letter-spacing: 0;
    }

    .dt-artifact-subtitle {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      font-size: 12px;
      color: var(--text-muted);
    }

    .dt-artifact-source {
      color: var(--text-secondary);
    }

    .dt-artifact-source::before {
      content: "Source:";
      color: var(--text-muted);
      margin-right: 4px;
    }

    .dt-metric-strip {
      display: flex;
      align-items: center;
      gap: 6px;
      flex-wrap: wrap;
    }

    .dt-metric-pill {
      font-size: 11px;
      color: var(--text-secondary);
      font-family: 'Fragment Mono', monospace;
      padding: 3px 8px;
      background: var(--bg-deep);
      border: 1px solid var(--border);
      border-radius: 4px;
    }

    .dt-surface-notice {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 14px;
      padding: 12px 20px;
      border-bottom: 1px solid var(--border);
      background: color-mix(in srgb, var(--bg-shelf) 78%, var(--bg-surface));
      flex-shrink: 0;
    }
    .dt-surface-copy {
      display: flex;
      min-width: 0;
      flex-direction: column;
      gap: 3px;
      color: var(--text-muted);
      font-size: 12px;
      line-height: 1.35;
    }
    .dt-surface-copy strong {
      color: var(--text-primary);
      font-size: 13px;
      font-weight: 700;
    }
    .dt-surface-label {
      color: var(--accent, #e07a2f);
      font-size: 10px;
      font-weight: 750;
      letter-spacing: 0;
      text-transform: uppercase;
    }
    .dt-surface-count {
      display: grid;
      place-items: center;
      min-width: 74px;
      padding: 7px 10px;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--bg-surface);
    }
    .dt-surface-count strong {
      color: var(--text-primary);
      font-family: 'Fragment Mono', monospace;
      font-size: 17px;
      line-height: 1;
    }
    .dt-surface-count span,
    .dt-surface-state {
      color: var(--text-muted);
      font-size: 11px;
      font-weight: 650;
    }
    .dt-surface-state {
      flex: 0 0 auto;
      padding: 6px 10px;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: var(--bg-surface);
    }
    .dt-surface-state.is-ready {
      color: var(--green);
      border-color: color-mix(in srgb, var(--green) 50%, var(--border));
    }
    .dt-surface-state.needs-work {
      color: var(--accent, #e07a2f);
      border-color: color-mix(in srgb, var(--accent, #e07a2f) 45%, var(--border));
    }

    .dt-row-count-legacy,
    .dt-row-count {
      font-size: 11px;
      color: var(--text-muted);
      font-family: 'Fragment Mono', monospace;
      padding: 3px 10px;
      background: var(--bg-deep);
      border-radius: 10px;
    }

    .dt-cost {
      font-size: 11px;
      color: var(--teal);
      font-family: 'Fragment Mono', monospace;
      margin-left: auto;
      padding: 3px 10px;
      background: var(--teal-dim);
      border-radius: 10px;
    }
    .dt-metric-strip .dt-cost { margin-left: 0; }

    """
  end
end
