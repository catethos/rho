defmodule RhoWeb.InlineCSS.Flow do
  @moduledoc false

  def css do
    ~S"""
    /* === Flow Wizard === */
    .flow-container {
      max-width: 860px;
      margin: 2rem auto;
      padding: 0 1.5rem;
    }
    .flow-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 1rem;
      flex-wrap: wrap;
      margin-bottom: 1.5rem;
    }
    .flow-title {
      font-size: 1.5rem;
      font-weight: 600;
      color: var(--text-primary);
      letter-spacing: -0.02em;
    }

    /* Mode toggle (Phase 5) */
    .flow-mode-toggle {
      display: inline-flex;
      align-items: center;
      gap: 0;
      padding: 0.1875rem;
      background: var(--bg-mid);
      border: 1px solid var(--border);
      border-radius: 999px;
      flex-shrink: 0;
    }
    .flow-mode-button {
      appearance: none;
      border: none;
      background: transparent;
      padding: 0.375rem 0.875rem;
      font-size: 0.8125rem;
      font-weight: 500;
      color: var(--text-secondary);
      cursor: pointer;
      border-radius: 999px;
      transition: background 0.15s ease, color 0.15s ease, box-shadow 0.15s ease;
    }
    .flow-mode-button:hover {
      color: var(--text-primary);
    }
    .flow-mode-button-active {
      background: var(--bg-surface);
      color: var(--text-primary);
      box-shadow: var(--shadow-sm);
    }

    /* Routing chip (Phase 5) — shown on :auto-routed nodes when mode != guided */
    .routing-chip {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      margin: 0 0 1.25rem 0;
      padding: 0.875rem 1rem;
      background: var(--violet-dim);
      border: 1px solid var(--border-violet);
      border-radius: var(--radius);
    }
    .routing-chip-row {
      display: flex;
      align-items: center;
      gap: 0.625rem;
    }
    .routing-chip-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      flex-shrink: 0;
      background: var(--text-muted);
    }
    .routing-chip-dot-high { background: var(--green); }
    .routing-chip-dot-mid { background: var(--teal); }
    .routing-chip-dot-low { background: var(--red); }
    .routing-chip-dot-unknown { background: var(--text-muted); }
    .routing-chip-headline {
      flex: 1;
      color: var(--text-primary);
      font-size: 0.9rem;
    }
    .routing-chip-confidence {
      font-family: var(--font-mono);
      font-size: 0.75rem;
      color: var(--text-muted);
      margin-left: 0.25rem;
    }
    .routing-chip-override {
      flex-shrink: 0;
      appearance: none;
      border: 1px solid var(--border);
      background: var(--bg-surface);
      color: var(--text-primary);
      padding: 0.25rem 0.625rem;
      font-size: 0.75rem;
      font-weight: 500;
      border-radius: 999px;
      cursor: pointer;
      transition: background 0.15s ease, border-color 0.15s ease;
    }
    .routing-chip-override:hover {
      background: var(--bg-hover);
      border-color: var(--border-active);
    }
    .routing-chip-reason {
      margin: 0;
      padding-left: 1.125rem;
      color: var(--text-secondary);
      font-size: 0.8125rem;
      line-height: 1.45;
    }
    .routing-chip-options {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
      padding-top: 0.5rem;
      border-top: 1px solid var(--border-violet);
    }
    .routing-chip-option {
      appearance: none;
      border: 1px solid var(--border);
      background: var(--bg-surface);
      color: var(--text-primary);
      padding: 0.375rem 0.75rem;
      font-size: 0.8125rem;
      font-weight: 500;
      border-radius: var(--radius);
      cursor: pointer;
      transition: background 0.15s ease, border-color 0.15s ease;
    }
    .routing-chip-option:hover:not(:disabled) {
      background: var(--bg-hover);
      border-color: var(--border-active);
    }
    .routing-chip-option:disabled,
    .routing-chip-option-active {
      background: var(--teal-dim);
      border-color: var(--teal-glow-strong);
      color: var(--text-primary);
      cursor: default;
    }

    /* Research panel tool log (Phase 5 — gated by show_theater) */
    .research-tool-log {
      padding: 0.5rem 0.75rem;
      background: var(--bg-mid);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      font-family: var(--font-mono);
      font-size: 0.75rem;
    }

    /* Stepper */
    .flow-stepper {
      display: flex;
      align-items: center;
      gap: 0;
      margin-bottom: 2rem;
      padding: 1rem 0;
    }
    .flow-step {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      white-space: nowrap;
    }
    .flow-step-number {
      width: 28px;
      height: 28px;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 0.75rem;
      font-weight: 600;
      border: 2px solid var(--border);
      color: var(--text-muted);
      background: var(--bg-surface);
      flex-shrink: 0;
    }
    .flow-step-label {
      font-size: 0.8rem;
      color: var(--text-muted);
      font-weight: 500;
    }
    .flow-step-active .flow-step-number {
      border-color: var(--teal);
      color: var(--teal);
      background: var(--teal-dim);
    }
    .flow-step-active .flow-step-label {
      color: var(--text-primary);
      font-weight: 600;
    }
    .flow-step-completed .flow-step-number {
      border-color: var(--green);
      color: var(--green);
      background: var(--green-dim);
    }
    .flow-step-completed .flow-step-label {
      color: var(--text-secondary);
    }
    .flow-step-connector {
      flex: 1;
      height: 2px;
      background: var(--border);
      margin: 0 0.75rem;
      min-width: 16px;
    }
    .flow-step-more .flow-step-number {
      border-style: dashed;
      font-size: 1rem;
      line-height: 1;
    }
    .flow-step-more .flow-step-label {
      font-style: italic;
    }

    /* Step content area */
    .flow-step-content {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      padding: 2rem;
      box-shadow: var(--shadow-sm);
    }

    /* Chat-native flow surface */
    .flow-chat-native {
      display: flex;
      flex-direction: column;
      gap: 1rem;
    }
    .flow-chat-thread {
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
    }
    .flow-chat-bubble {
      align-self: flex-end;
      max-width: 78%;
      padding: 0.75rem 0.875rem;
      background: var(--bg-shelf);
      border: 1px solid var(--border);
      border-radius: var(--radius);
    }
    .flow-chat-bubble-head {
      display: flex;
      justify-content: space-between;
      gap: 1rem;
      color: var(--text-muted);
      font-size: 0.72rem;
      font-weight: 600;
      margin-bottom: 0.25rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .flow-chat-bubble p {
      margin: 0;
      color: var(--text-primary);
      font-size: 0.9rem;
      line-height: 1.45;
    }
    .flow-chat-card {
      display: flex;
      flex-direction: column;
      gap: 0.875rem;
      padding: 1rem;
      background: var(--bg-shelf);
      border: 1px solid var(--border);
      border-left: 3px solid var(--teal);
      border-radius: var(--radius);
    }
    .flow-chat-card-head {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 1rem;
    }
    .flow-chat-card h2 {
      margin: 0.125rem 0 0 0;
      color: var(--text-primary);
      font-size: 1rem;
      font-weight: 600;
      letter-spacing: 0;
    }
    .flow-chat-eyebrow,
    .flow-chat-kind,
    .flow-chat-node {
      color: var(--text-muted);
      font-size: 0.7rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .flow-chat-node {
      font-family: var(--font-mono);
      text-transform: none;
      letter-spacing: 0;
    }
    .flow-chat-body {
      margin: 0;
      color: var(--text-secondary);
      font-size: 0.92rem;
      line-height: 1.5;
    }
    .flow-chat-fields {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
      gap: 0.5rem;
    }
    .flow-chat-form {
      grid-template-columns: minmax(220px, 1fr) minmax(220px, 1fr) minmax(150px, 220px);
      align-items: end;
      column-gap: 0.75rem;
      row-gap: 0.75rem;
    }
    .flow-chat-form .flow-textarea {
      min-height: 3.2rem;
      height: 3.2rem;
      resize: vertical;
    }
    .flow-chat-form .flow-submit {
      width: 100%;
      min-height: 3.2rem;
      margin-top: 0;
    }
    .flow-chat-choice-form {
      grid-template-columns: minmax(260px, 420px) minmax(150px, 220px);
      justify-content: start;
    }
    .flow-chat-guided-form {
      grid-template-columns: repeat(2, minmax(260px, 1fr));
      align-items: start;
      column-gap: 2rem;
      row-gap: 1.75rem;
      max-width: 980px;
    }
    .flow-chat-guided-form .flow-submit {
      grid-column: 1 / -1;
      justify-self: start;
      width: min(280px, 100%);
      margin-top: 0.25rem;
    }
    .flow-chat-guided-form .flow-field {
      gap: 0.55rem;
    }
    .flow-chat-field-chip {
      display: flex;
      flex-direction: column;
      gap: 0.125rem;
      padding: 0.55rem 0.65rem;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-sm);
      min-width: 0;
    }
    .flow-chat-field-chip span {
      color: var(--text-muted);
      font-size: 0.72rem;
    }
    .flow-chat-field-chip strong {
      color: var(--text-primary);
      font-size: 0.84rem;
      font-weight: 600;
      overflow-wrap: anywhere;
    }
    .flow-chat-artifact {
      padding: 0.55rem 0.65rem;
      background: var(--teal-dim);
      border: 1px solid var(--teal-glow-strong);
      border-radius: var(--radius-sm);
      color: var(--text-primary);
      font-size: 0.84rem;
      font-family: var(--font-mono);
      overflow-wrap: anywhere;
    }
    .flow-chat-empty-state,
    .flow-chat-selection {
      display: flex;
      flex-direction: column;
      gap: 0.625rem;
      padding: 0.75rem;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-sm);
    }
    .flow-chat-empty-title {
      color: var(--text-primary);
      font-size: 0.92rem;
      font-weight: 600;
    }
    .flow-chat-empty-state p {
      margin: 0;
      color: var(--text-secondary);
      font-size: 0.84rem;
      line-height: 1.45;
    }
    .flow-chat-selection-summary {
      display: flex;
      flex-direction: column;
      gap: 0.125rem;
    }
    .flow-chat-selection-summary strong {
      color: var(--text-primary);
      font-size: 0.9rem;
    }
    .flow-chat-selection-summary span {
      color: var(--text-secondary);
      font-size: 0.82rem;
      line-height: 1.4;
    }
    .flow-chat-selection-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 0.5rem;
    }
    .flow-chat-selection-card {
      display: grid;
      grid-template-columns: 1rem minmax(0, 1fr);
      gap: 0.5rem;
      align-items: flex-start;
      min-height: 4rem;
      padding: 0.65rem;
      background: var(--bg-shelf);
      border: 1px solid var(--border);
      border-radius: var(--radius-sm);
      color: var(--text-primary);
      text-align: left;
      cursor: pointer;
    }
    .flow-chat-selection-card:hover {
      border-color: var(--teal-glow-strong);
    }
    .flow-chat-selection-card-selected {
      background: var(--teal-dim);
      border-color: var(--teal-glow-strong);
    }
    .flow-chat-selection-check {
      display: inline-grid;
      place-items: center;
      width: 1rem;
      height: 1rem;
      border: 1px solid var(--border-strong);
      border-radius: 4px;
      color: var(--text-primary);
      font-size: 0.72rem;
      line-height: 1;
    }
    .flow-chat-selection-card-selected .flow-chat-selection-check {
      background: var(--teal);
      border-color: var(--teal);
      color: var(--bg-base);
    }
    .flow-chat-selection-text {
      display: flex;
      min-width: 0;
      flex-direction: column;
      gap: 0.15rem;
    }
    .flow-chat-selection-text strong {
      overflow-wrap: anywhere;
      font-size: 0.86rem;
      font-weight: 600;
    }
    .flow-chat-selection-text small {
      color: var(--text-muted);
      font-size: 0.74rem;
      line-height: 1.35;
    }
    .flow-chat-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
    }
    .flow-chat-action {
      border-radius: var(--radius);
    }
    .flow-chat-reply {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 0.5rem;
      padding-top: 0.25rem;
    }
    .flow-chat-error {
      margin: 0;
      padding: 0.5rem 0.65rem;
      background: var(--red-dim);
      color: var(--red);
      border-radius: var(--radius-sm);
      font-size: 0.82rem;
    }
    .flow-chat-artifact-surface {
      padding-top: 1rem;
      border-top: 1px solid var(--border);
    }

    /* Form step */
    .flow-form {
      display: flex;
      flex-direction: column;
      gap: 1.25rem;
    }
    .flow-field {
      display: flex;
      flex-direction: column;
      gap: 0.35rem;
    }
    .flow-label {
      font-size: 0.85rem;
      font-weight: 500;
      color: var(--text-secondary);
    }
    .flow-required {
      color: var(--red);
    }
    .flow-field-help {
      margin: -0.1rem 0 0;
      color: var(--text-muted);
      font-size: 0.76rem;
      line-height: 1.35;
    }
    .flow-selected-hint {
      display: grid;
      grid-template-columns: minmax(5.5rem, max-content) 1fr;
      gap: 0.55rem;
      margin: 0;
      padding-left: 0.65rem;
      border-left: 2px solid var(--border);
      color: var(--text-muted);
      font-size: 0.74rem;
      line-height: 1.3;
    }
    .flow-selected-hint strong {
      color: var(--text-secondary);
      font-weight: 600;
    }
    .flow-option-guide {
      color: var(--text-muted);
      font-size: 0.74rem;
    }
    .flow-option-guide summary {
      cursor: pointer;
      width: max-content;
      color: var(--text-secondary);
      font-weight: 600;
    }
    .flow-option-guide[open] summary {
      margin-bottom: 0.45rem;
    }
    .flow-option-hints {
      display: grid;
      gap: 0.25rem;
      margin-top: 0.05rem;
    }
    .flow-option-hint {
      display: grid;
      grid-template-columns: minmax(5.5rem, max-content) 1fr;
      gap: 0.45rem;
      align-items: baseline;
      color: var(--text-muted);
      font-size: 0.72rem;
      line-height: 1.25;
    }
    .flow-option-hint strong {
      color: var(--text-secondary);
      font-weight: 600;
    }
    .flow-input {
      padding: 0.6rem 0.75rem;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      font-size: 0.9rem;
      font-family: var(--font-body);
      background: var(--bg-shelf);
      color: var(--text-primary);
      transition: border-color 0.15s;
    }
    .flow-input:focus {
      outline: none;
      border-color: var(--teal);
      box-shadow: 0 0 0 3px var(--teal-dim);
    }
    .flow-textarea {
      resize: vertical;
      min-height: 100px;
    }
    .flow-submit {
      align-self: flex-end;
      margin-top: 0.5rem;
    }
    .flow-submit:disabled {
      opacity: 0.45;
      cursor: not-allowed;
    }

    @media (max-width: 900px) {
      .flow-chat-form {
        grid-template-columns: 1fr;
      }
      .flow-chat-form .flow-submit {
        width: auto;
        justify-self: start;
      }
      .flow-chat-guided-form {
        grid-template-columns: 1fr;
        row-gap: 1.25rem;
      }
    }

    /* Conflict resolution step */
    .flow-conflict-resolve { display: flex; flex-direction: column; gap: 1rem; }
    .flow-conflict-empty {
      display: flex; flex-direction: column; align-items: center; gap: 1rem;
      padding: 2rem 0; color: var(--text-secondary);
    }
    .flow-conflict-list { display: flex; flex-direction: column; gap: 0.75rem; }
    .flow-conflict-summary {
      font-size: 0.85rem; font-weight: 500;
      color: var(--text-secondary);
      padding-bottom: 0.5rem;
      border-bottom: 1px solid var(--border);
      margin: 0;
    }
    .flow-conflict-row {
      position: relative;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-left: 3px solid var(--border);
      border-radius: var(--radius);
      padding: 0.85rem 1rem;
      display: flex; flex-direction: column; gap: 0.6rem;
      transition: opacity 0.15s, border-color 0.15s, background 0.15s;
    }
    .flow-conflict-unresolved {
      border-left-color: var(--teal);
      background: var(--bg-surface);
    }
    .flow-conflict-merge_a,
    .flow-conflict-merge_b,
    .flow-conflict-keep_both {
      border-left-color: var(--green);
      background: var(--green-dim);
      opacity: 0.78;
    }
    .flow-conflict-merge_a::after,
    .flow-conflict-merge_b::after,
    .flow-conflict-keep_both::after {
      content: "✓";
      position: absolute;
      top: 0.75rem; right: 0.85rem;
      color: var(--green);
      font-weight: 600;
      font-size: 0.95rem;
    }
    .flow-conflict-row-header {
      display: flex; align-items: center; gap: 0.5rem;
      font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.04em;
    }
    .flow-conflict-confidence {
      color: var(--text-muted);
      font-weight: 600;
    }
    .flow-conflict-category {
      color: var(--text-secondary);
      padding: 0.1rem 0.4rem;
      background: var(--bg-shelf);
      border-radius: var(--radius-sm);
    }
    .flow-conflict-pair {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 0.75rem;
    }
    .flow-conflict-side {
      display: flex; flex-direction: column; gap: 0.2rem;
      padding: 0.5rem 0.65rem;
      background: var(--bg-shelf);
      border-radius: var(--radius-sm);
      font-size: 0.85rem;
    }
    .flow-conflict-side-label {
      font-size: 0.7rem; font-weight: 600;
      color: var(--text-muted);
      text-transform: uppercase; letter-spacing: 0.04em;
    }
    .flow-conflict-side-name {
      font-weight: 600;
      color: var(--text-primary);
    }
    .flow-conflict-side-desc {
      color: var(--text-secondary);
      font-size: 0.8rem;
      line-height: 1.4;
    }
    .flow-conflict-actions {
      display: flex; gap: 0.4rem; flex-wrap: wrap;
    }
    .flow-conflict-action-active {
      background: var(--green);
      color: var(--bg-surface);
      border-color: var(--green);
      font-weight: 600;
    }
    .flow-conflict-action-active:hover {
      background: var(--green);
      border-color: var(--green);
      filter: brightness(0.95);
    }

    /* Action step */
    .flow-action-status {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 1rem;
      padding: 2rem 0;
    }
    .flow-action-running {
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
      color: var(--text-secondary);
      font-size: 0.95rem;
      width: 100%;
    }
    .flow-action-header {
      display: flex;
      align-items: center;
      gap: 0.75rem;
    }
    .flow-action-complete {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 1rem;
      color: var(--green);
      font-size: 0.95rem;
    }
    .flow-action-error {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 0.75rem;
      color: var(--red);
      font-size: 0.9rem;
    }
    .flow-error-icon {
      width: 24px;
      height: 24px;
      border-radius: 50%;
      background: var(--red-dim);
      color: var(--red);
      display: flex;
      align-items: center;
      justify-content: center;
      font-weight: 700;
      font-size: 0.85rem;
    }

    /* Tool log */
    .flow-tool-log {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
      padding: 0.5rem 0;
    }
    .flow-tool-event {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      font-size: 0.8rem;
      font-family: var(--font-mono);
    }
    .flow-tool-name {
      color: var(--teal-bright);
      font-weight: 500;
    }
    .flow-tool-phase {
      color: var(--text-muted);
    }
    .flow-tool-ok { color: var(--green); }
    .flow-tool-error { color: var(--red); }

    /* Streaming output */
    .flow-stream-output {
      max-height: 300px;
      overflow-y: auto;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      background: var(--bg-shelf);
      padding: 0.75rem;
    }
    .flow-stream-text {
      font-family: var(--font-mono);
      font-size: 0.78rem;
      color: var(--text-secondary);
      white-space: pre-wrap;
      word-break: break-word;
      margin: 0;
    }

    /* Spinner */
    .flow-spinner {
      width: 22px;
      height: 22px;
      border: 2.5px solid var(--border);
      border-top-color: var(--teal);
      border-radius: 50%;
      animation: flow-spin 0.7s linear infinite;
    }
    .flow-spinner-sm {
      width: 14px;
      height: 14px;
      border: 2px solid var(--border);
      border-top-color: var(--teal);
      border-radius: 50%;
      animation: flow-spin 0.7s linear infinite;
    }
    @keyframes flow-spin {
      to { transform: rotate(360deg); }
    }

    /* Table review */
    .flow-table-review {
      display: flex;
      flex-direction: column;
      gap: 1.5rem;
    }
    .flow-table-wrap {
      max-height: 480px;
      overflow-y: auto;
      border: 1px solid var(--border);
      border-radius: var(--radius);
    }
    .flow-table-empty {
      padding: 2rem;
      text-align: center;
      color: var(--text-muted);
    }

    /* Fan-out / worker grid */
    .flow-fan-out {
      display: flex;
      flex-direction: column;
      gap: 1.5rem;
    }
    .flow-fan-out-start {
      display: flex;
      justify-content: center;
      padding: 1rem 0;
    }
    .flow-fan-out-done {
      display: flex;
      justify-content: center;
      padding: 0.5rem 0;
    }
    .flow-worker-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
      gap: 0.75rem;
    }
    .flow-progress-card {
      background: var(--bg-shelf);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 0.75rem 1rem;
    }
    .flow-progress-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 0.5rem;
    }
    .flow-progress-category {
      font-size: 0.85rem;
      font-weight: 600;
      color: var(--text-primary);
    }
    .flow-progress-count {
      font-size: 0.75rem;
      color: var(--text-muted);
      font-family: var(--font-mono);
    }
    .flow-progress-status {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      font-size: 0.8rem;
      color: var(--text-secondary);
    }
    .flow-status-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
    }
    .flow-status-pending { background: var(--text-muted); }
    .flow-status-completed { background: var(--green); }
    .flow-status-failed { background: var(--red); }
    .flow-progress-completed {
      border-color: rgba(107, 158, 120, 0.25);
    }
    .flow-progress-failed {
      border-color: rgba(199, 92, 84, 0.25);
    }

    /* === Flow: Range input === */
    .flow-range-wrap {
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .flow-range {
      flex: 1;
      height: 6px;
      -webkit-appearance: none;
      appearance: none;
      background: var(--bg-deep);
      border-radius: 3px;
      outline: none;
    }
    .flow-range::-webkit-slider-thumb {
      -webkit-appearance: none;
      width: 18px;
      height: 18px;
      border-radius: 50%;
      background: var(--accent, #B87333);
      cursor: pointer;
    }
    .flow-range-value {
      min-width: 28px;
      text-align: center;
      font-weight: 600;
      color: var(--text-primary);
      font-size: 0.875rem;
    }

    /* === Flow: Select dropdown === */
    .flow-select {
      cursor: pointer;
    }

    /* === Flow: Select step (cards) === */
    .flow-select-step {
      display: flex;
      flex-direction: column;
      gap: 16px;
    }
    .flow-select-loading {
      display: flex;
      align-items: center;
      gap: 10px;
      color: var(--text-muted);
      padding: 24px 0;
    }
    .flow-select-hint {
      color: var(--text-secondary);
      font-size: 0.875rem;
    }
    .flow-select-grid {
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .flow-select-card {
      display: flex;
      align-items: flex-start;
      gap: 12px;
      padding: 12px 16px;
      border: 1px solid var(--bg-deep);
      border-radius: 8px;
      background: var(--bg-surface);
      cursor: pointer;
      transition: border-color 0.15s, background 0.15s;
    }
    .flow-select-card:hover {
      border-color: var(--accent, #B87333);
      background: var(--bg-hover);
    }
    .flow-select-card-active {
      border-color: var(--accent, #B87333);
      background: rgba(184, 115, 51, 0.05);
    }
    .flow-checkbox {
      width: 18px;
      height: 18px;
      border: 2px solid var(--text-muted);
      border-radius: 4px;
      display: flex;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
      margin-top: 2px;
      transition: border-color 0.15s, background 0.15s;
    }
    .flow-checkbox-checked {
      border-color: var(--accent, #B87333);
      background: var(--accent, #B87333);
      color: #fff;
    }
    .flow-select-card-body {
      display: flex;
      flex-direction: column;
      gap: 2px;
    }
    .flow-select-card-title {
      font-weight: 600;
      color: var(--text-primary);
      font-size: 0.875rem;
    }
    .flow-select-card-subtitle {
      color: var(--text-secondary);
      font-size: 0.8125rem;
    }
    .flow-select-card-detail {
      color: var(--text-muted);
      font-size: 0.75rem;
    }
    .flow-select-actions {
      display: flex;
      align-items: center;
      gap: 12px;
      padding-top: 8px;
    }
    .flow-skip {
      background: transparent;
      border: 1px solid var(--text-muted);
      color: var(--text-secondary);
      padding: 8px 20px;
      border-radius: 6px;
      cursor: pointer;
      font-size: 0.875rem;
    }
    .flow-skip:hover {
      border-color: var(--text-secondary);
      color: var(--text-primary);
    }
    .flow-select-empty {
      color: var(--text-muted);
      padding: 16px 0;
    }

    /* === Flow: Confirm step === */
    .flow-confirm {
      display: flex;
      flex-direction: column;
      align-items: flex-start;
      gap: 16px;
      padding: 16px 0;
    }
    .flow-confirm-message {
      color: var(--text-secondary);
      font-size: 0.9375rem;
      line-height: 1.5;
    }

    /* === Research panel === */
    .research-panel {
      display: flex;
      flex-direction: column;
      gap: 1rem;
      padding: 1.25rem;
      background: var(--bg-shelf);
      border: 1px solid var(--border);
      border-radius: var(--radius);
    }
    .research-panel-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 1rem;
      padding-bottom: 0.75rem;
      border-bottom: 1px solid var(--border);
    }
    .research-panel-title {
      display: flex;
      align-items: center;
      gap: 0.625rem;
      color: var(--text-primary);
      font-size: 0.9375rem;
      font-weight: 500;
    }
    .research-panel-counts {
      color: var(--text-muted);
      font-size: 0.8125rem;
      font-weight: 400;
      font-family: var(--font-mono);
      margin-left: 0.25rem;
    }
    .research-continue {
      flex-shrink: 0;
    }
    .research-error {
      padding: 0.625rem 0.75rem;
      background: var(--red-dim);
      color: var(--red);
      border-radius: var(--radius);
      font-size: 0.85rem;
    }
    .research-findings {
      list-style: none;
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      max-height: 420px;
      overflow-y: auto;
      padding: 0;
      margin: 0;
    }
    .research-finding {
      display: flex;
      align-items: flex-start;
      gap: 0.75rem;
      padding: 0.75rem 0.875rem;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      transition: border-color 0.15s ease, background 0.15s ease;
    }
    .research-finding:hover {
      border-color: var(--border-active);
    }
    .research-finding-pinned {
      background: var(--teal-dim);
      border-color: var(--teal-glow-strong);
    }
    .research-pin {
      flex-shrink: 0;
      width: 28px;
      height: 28px;
      border: none;
      background: transparent;
      cursor: pointer;
      border-radius: 4px;
      font-size: 1.125rem;
      line-height: 1;
      color: var(--text-muted);
      transition: color 0.12s ease, background 0.12s ease;
    }
    .research-pin:hover {
      background: var(--bg-hover);
    }
    .research-pin-on {
      color: var(--teal);
    }
    .research-pin-off:hover {
      color: var(--text-secondary);
    }
    .research-finding-body {
      flex: 1;
      display: flex;
      flex-direction: column;
      gap: 0.375rem;
      min-width: 0;
    }
    .research-fact {
      color: var(--text-primary);
      font-size: 0.9rem;
      line-height: 1.45;
      margin: 0;
    }
    .research-meta {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      flex-wrap: wrap;
    }
    .research-tag {
      display: inline-block;
      padding: 0.0625rem 0.5rem;
      background: var(--violet-dim);
      color: var(--violet);
      border-radius: 999px;
      font-size: 0.7rem;
      font-weight: 500;
      letter-spacing: 0.02em;
      text-transform: uppercase;
    }
    .research-source {
      font-family: var(--font-mono);
      font-size: 0.7rem;
      color: var(--text-muted);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      min-width: 0;
    }
    .research-empty {
      padding: 1.5rem 0.875rem;
      text-align: center;
      color: var(--text-muted);
      font-size: 0.85rem;
      font-style: italic;
      background: var(--bg-mid);
      border: 1px dashed var(--border);
      border-radius: var(--radius);
    }
    .research-add-note {
      display: flex;
      gap: 0.5rem;
      padding-top: 0.75rem;
      border-top: 1px solid var(--border);
    }
    .research-add-note .flow-input {
      flex: 1;
    }

    /* === Smart-entry card (libraries landing — Phase 9) === */
    .smart-entry {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      padding: 1.25rem 1.5rem;
      margin-bottom: 1.5rem;
      background: var(--bg-shelf);
      border: 1px solid var(--border);
      border-radius: var(--radius);
    }
    .smart-entry-title {
      margin: 0;
      color: var(--text-primary);
      font-size: 1rem;
      font-weight: 600;
    }
    .smart-entry-hint {
      margin: 0 0 0.5rem 0;
      color: var(--text-secondary);
      font-size: 0.875rem;
      line-height: 1.5;
    }
    .smart-entry-hint em {
      font-style: italic;
      color: var(--text-primary);
    }
    .smart-entry-form {
      display: flex;
      align-items: flex-start;
      gap: 0.75rem;
    }
    .smart-entry-textarea {
      flex: 1;
      padding: 0.6rem 0.75rem;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      font-size: 0.9rem;
      font-family: var(--font-body);
      background: var(--bg-surface);
      color: var(--text-primary);
      resize: vertical;
      min-height: 56px;
      transition: border-color 0.15s, box-shadow 0.15s;
    }
    .smart-entry-textarea:focus {
      outline: none;
      border-color: var(--teal);
      box-shadow: 0 0 0 3px var(--teal-dim);
    }
    .smart-entry-textarea:disabled {
      opacity: 0.6;
      cursor: not-allowed;
    }

    /* === Step chat (in-wizard escape hatch — Phase 8) === */
    .step-chat {
      display: flex;
      flex-direction: column;
      gap: 0.625rem;
      padding: 1rem 1.25rem;
      margin-top: 1.25rem;
      background: var(--bg-mid);
      border: 1px solid var(--border);
      border-radius: var(--radius);
    }
    .step-chat-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
    }
    .step-chat-title {
      color: var(--text-secondary);
      font-size: 0.8125rem;
      font-weight: 500;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .step-chat-status {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      color: var(--text-muted);
      font-size: 0.8125rem;
    }
    .step-chat-spinner {
      width: 12px;
      height: 12px;
    }
    .step-chat-pending {
      padding: 0.625rem 0.75rem;
      background: var(--violet-dim);
      border-left: 3px solid var(--violet);
      border-radius: var(--radius);
    }
    .step-chat-pending-label {
      display: block;
      color: var(--violet);
      font-size: 0.7rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      margin-bottom: 0.25rem;
    }
    .step-chat-pending-question {
      margin: 0;
      color: var(--text-primary);
      font-size: 0.9rem;
      line-height: 1.45;
    }
    .step-chat-form {
      display: flex;
      align-items: flex-start;
      gap: 0.5rem;
    }
    .step-chat-textarea {
      flex: 1;
      padding: 0.5rem 0.625rem;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      font-size: 0.875rem;
      font-family: var(--font-body);
      background: var(--bg-surface);
      color: var(--text-primary);
      resize: vertical;
      min-height: 44px;
      transition: border-color 0.15s, box-shadow 0.15s;
    }
    .step-chat-textarea:focus {
      outline: none;
      border-color: var(--teal);
      box-shadow: 0 0 0 3px var(--teal-dim);
    }
    .step-chat-textarea:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    .step-chat-submit:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    .step-chat-stream {
      padding: 0.625rem 0.75rem;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      color: var(--text-secondary);
      font-size: 0.85rem;
      line-height: 1.45;
      white-space: pre-wrap;
    }
    .step-chat-tool-log {
      list-style: none;
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
      padding: 0;
      margin: 0;
    }
    .step-chat-tool {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding: 0.25rem 0.5rem;
      font-family: var(--font-mono);
      font-size: 0.75rem;
      color: var(--text-muted);
    }

    /* === Action step summary lines === */
    .flow-action-headline {
      color: var(--text-primary);
      font-size: 1rem;
      font-weight: 500;
    }
    .flow-action-detail {
      color: var(--text-secondary);
      font-size: 0.875rem;
    }
    .flow-final-complete {
      padding: 2.5rem 0;
      gap: 0.75rem;
    }

    /* === Library page: archived research notes === */
    .research-archive {
      background: var(--bg-shelf);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      margin-bottom: 1rem;
      overflow: hidden;
    }
    .research-archive-summary {
      list-style: none;
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding: 0.75rem 1rem;
      color: var(--text-primary);
      font-size: 0.9375rem;
      font-weight: 500;
    }
    .research-archive-summary::-webkit-details-marker { display: none; }
    .research-archive-summary:hover {
      background: var(--bg-hover);
    }
    .research-archive-arrow {
      width: 0;
      height: 0;
      border-left: 5px solid transparent;
      border-right: 5px solid transparent;
      border-top: 6px solid var(--text-muted);
      transition: transform 0.15s ease;
      transform: rotate(-90deg);
    }
    details[open] > .research-archive-summary > .research-archive-arrow {
      transform: rotate(0deg);
    }
    .research-archive-title {
      flex: 1;
    }
    .research-archive-list {
      list-style: none;
      margin: 0;
      padding: 0.5rem 1rem 1rem;
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      border-top: 1px solid var(--border);
    }
    .research-archive-item {
      padding: 0.625rem 0.75rem;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      display: flex;
      flex-direction: column;
      gap: 0.375rem;
    }
    .research-archive-by {
      font-family: var(--font-mono);
      font-size: 0.7rem;
      color: var(--text-muted);
      font-style: italic;
    }
    """
  end
end
