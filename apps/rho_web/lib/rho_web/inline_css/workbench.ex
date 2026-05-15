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
      width: min(1060px, 100%);
      margin: 0 auto;
      display: grid;
      gap: 22px;
    }

    .workbench-home-hero {
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(240px, 320px);
      gap: 18px;
      align-items: stretch;
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

    .workbench-primary-action {
      position: relative;
      min-height: 210px;
      display: flex;
      flex-direction: column;
      justify-content: flex-end;
      align-items: flex-start;
      gap: 10px;
      padding: 22px;
      border: 1px solid rgba(224, 122, 47, 0.55);
      border-radius: 8px;
      background:
        linear-gradient(145deg, rgba(224, 122, 47, 0.19), rgba(224, 122, 47, 0.04) 58%),
        var(--bg-surface);
      color: var(--text-primary);
      text-align: left;
      cursor: pointer;
      overflow: hidden;
      box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.42), 0 18px 46px rgba(30, 24, 18, 0.08);
      transition: border-color 140ms ease, transform 140ms ease, box-shadow 140ms ease;
    }

    .workbench-primary-action::before {
      content: '';
      position: absolute;
      top: 18px;
      right: 18px;
      width: 48px;
      height: 48px;
      border: 1px solid rgba(224, 122, 47, 0.45);
      border-radius: 50%;
      background:
        linear-gradient(90deg, transparent 23px, rgba(224, 122, 47, 0.45) 24px, transparent 25px),
        linear-gradient(0deg, transparent 23px, rgba(224, 122, 47, 0.45) 24px, transparent 25px);
    }

    .workbench-primary-action:hover {
      border-color: var(--accent, #e07a2f);
      transform: translateY(-2px);
      box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.48), 0 22px 54px rgba(30, 24, 18, 0.12);
    }

    .workbench-action-eyebrow {
      color: var(--accent, #e07a2f);
      font-size: 0.72rem;
      font-weight: 800;
      text-transform: uppercase;
      letter-spacing: 0;
    }

    .workbench-primary-label {
      font-size: 1.35rem;
      line-height: 1.1;
      font-weight: 780;
    }

    .workbench-primary-summary {
      color: var(--text-secondary);
      font-size: 0.9rem;
      line-height: 1.45;
      max-width: 240px;
    }

    .workbench-home-body {
      display: block;
    }

    .workbench-action-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 12px;
    }

    .workbench-action-card {
      min-height: 148px;
      display: flex;
      flex-direction: column;
      align-items: flex-start;
      gap: 10px;
      padding: 16px;
      background: color-mix(in srgb, var(--bg-surface) 92%, white 8%);
      border: 1px solid var(--border);
      border-radius: 8px;
      color: var(--text-primary);
      text-align: left;
      cursor: pointer;
      transition: border-color 120ms ease, transform 120ms ease, background 120ms ease;
    }

    .workbench-action-card:hover {
      border-color: var(--accent, #e07a2f);
      background: var(--bg-elevated);
      transform: translateY(-1px);
    }

    .workbench-action-index {
      color: var(--accent, #e07a2f);
      font-size: 0.72rem;
      line-height: 1;
      font-weight: 800;
      font-variant-numeric: tabular-nums;
    }

    .workbench-action-label {
      font-size: 0.98rem;
      font-weight: 720;
      line-height: 1.2;
    }

    .workbench-action-summary {
      color: var(--text-secondary);
      font-size: 0.86rem;
      line-height: 1.45;
    }

    @media (max-width: 980px) {
      .workbench-home {
        justify-content: flex-start;
        padding: 22px;
      }

      .workbench-home-hero,
      .workbench-home-body {
        grid-template-columns: 1fr;
      }

      .workbench-action-grid {
        grid-template-columns: 1fr;
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
