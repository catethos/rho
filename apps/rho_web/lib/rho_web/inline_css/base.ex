defmodule RhoWeb.InlineCSS.Base do
  @moduledoc false

  def css do
    ~S"""
    /* === Reset & Base === */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      /* Warm ivory backgrounds */
      --bg-abyss: #F6F4F0;
      --bg-deep: #EDEAE4;
      --bg-mid: #F2F0EB;
      --bg-shelf: #FAF9F7;
      --bg-surface: #FFFFFF;
      --bg-hover: #F0EDE8;

      /* Borders — warm gray */
      --border: #E2DFD8;
      --border-active: #C9C5BC;
      --border-violet: rgba(120, 100, 160, 0.18);

      /* Text — ink-warm */
      --text-primary: #1C1917;
      --text-secondary: #57534E;
      --text-muted: #A8A29E;
      --text-teal: #B07640;
      --text-glow: #C2855A;

      /* Primary accent — warm copper */
      --teal: #C2855A;
      --teal-bright: #B07640;
      --teal-dim: rgba(194, 133, 90, 0.07);
      --teal-glow: rgba(194, 133, 90, 0.10);
      --teal-glow-strong: rgba(194, 133, 90, 0.16);

      /* Secondary — slate blue */
      --violet: #7C8DB5;
      --violet-dim: rgba(124, 141, 181, 0.08);
      --violet-glow: rgba(124, 141, 181, 0.1);

      /* Semantic */
      --green: #6B9E78;
      --green-dim: rgba(107, 158, 120, 0.10);
      --amber: #C9A84C;
      --amber-dim: rgba(201, 168, 76, 0.10);
      --red: #C75C54;
      --red-dim: rgba(199, 92, 84, 0.08);
      --blue: #7C8DB5;
      --yellow: #C9A84C;

      /* Typography */
      --font-body: 'DM Sans', -apple-system, BlinkMacSystemFont, sans-serif;
      --font-mono: 'JetBrains Mono', 'SF Mono', 'Cascadia Code', monospace;

      /* Layout */
      --nav-height: 48px;

      /* Shape */
      --radius: 8px;
      --radius-sm: 5px;
      --radius-lg: 12px;

      /* Shadows — warm */
      --shadow-sm: 0 1px 3px rgba(28, 25, 23, 0.04), 0 1px 2px rgba(28, 25, 23, 0.02);
      --shadow-md: 0 4px 12px rgba(28, 25, 23, 0.06), 0 1px 3px rgba(28, 25, 23, 0.04);
      --shadow-lg: 0 12px 32px rgba(28, 25, 23, 0.08), 0 4px 8px rgba(28, 25, 23, 0.04);
    }

    body.rho-body {
      font-family: var(--font-body);
      background: var(--bg-abyss);
      color: var(--text-primary);
      height: 100vh;
      overflow: auto;
      -webkit-font-smoothing: antialiased;
      -moz-osx-font-smoothing: grayscale;
      font-weight: 400;
      letter-spacing: -0.006em;
      font-optical-sizing: auto;
    }

    body.rho-body > * { position: relative; z-index: 1; }

    /* Subtle grain texture overlay */
    body.rho-body::before {
      content: '';
      position: fixed;
      inset: 0;
      opacity: 0.3;
      pointer-events: none;
      z-index: 0;
      background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noise'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noise)' opacity='0.04'/%3E%3C/svg%3E");
    }

    /* === Flash messages === */
    .flash-container { position: fixed; top: 1rem; right: 1rem; z-index: 100; }
    .flash {
      padding: 0.75rem 1.25rem;
      border-radius: var(--radius);
      font-size: 0.85rem;
      margin-bottom: 0.5rem;
      max-width: 400px;
      cursor: pointer;
      box-shadow: var(--shadow-md);
      backdrop-filter: blur(8px);
    }
    .flash-info { background: rgba(124, 141, 181, 0.12); color: var(--blue); border: 1px solid rgba(124, 141, 181, 0.25); }
    .flash-error { background: var(--red-dim); color: var(--red); border: 1px solid rgba(199, 92, 84, 0.25); }

    /* === Session layout === */
    .session-layout {
      display: flex;
      flex-direction: column;
      height: calc(100vh - var(--nav-height));
      overflow: hidden;
    }

    /* === Header === */
    .session-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 1.5rem;
      height: 52px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border);
      flex-shrink: 0;
    }

    .header-left { display: flex; align-items: center; gap: 0.75rem; }
    .header-title {
      font-size: 1.05rem;
      font-weight: 600;
      color: var(--text-primary);
      letter-spacing: -0.02em;
    }
    .header-session-id {
      font-family: var(--font-mono);
      font-size: 0.7rem;
      color: var(--text-muted);
    }

    .header-right,
    .session-controls { display: flex; align-items: center; gap: 0.7rem; }
    .session-controls {
      justify-content: flex-end;
      min-width: 0;
      margin-left: auto;
      flex-shrink: 0;
    }
    .header-tokens {
      font-family: var(--font-mono);
      font-size: 0.7rem;
      color: var(--text-muted);
      white-space: nowrap;
    }
    .header-step-tokens { color: var(--text-muted); }
    .header-cached { color: var(--teal); }
    .header-reasoning { color: var(--violet); }
    .header-cost {
      font-family: var(--font-mono);
      font-size: 0.75rem;
      font-weight: 600;
      color: var(--text-secondary);
    }

    .header-action-btn {
      padding: 0.35rem 0.85rem;
      border-radius: var(--radius);
      border: 1px solid var(--border);
      background: var(--bg-surface);
      color: var(--text-secondary);
      font-size: 0.8rem;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.15s;
    }
    .header-action-btn:hover { background: var(--bg-hover); border-color: var(--border-active); }

    .btn-stop {
      padding: 0.35rem 0.85rem;
      border-radius: var(--radius);
      border: 1px solid rgba(229, 83, 75, 0.2);
      background: var(--red-dim);
      color: var(--red);
      font-size: 0.8rem;
      font-weight: 500;
      cursor: pointer;
      transition: opacity 0.15s;
    }
    .btn-stop:hover { opacity: 0.8; }

    .header-avatar-form { display: flex; align-items: center; margin: 0; }
    .header-avatar {
      width: 28px;
      height: 28px;
      border-radius: 50%;
      cursor: pointer;
      overflow: hidden;
      display: flex;
      align-items: center;
      justify-content: center;
      border: 1.5px solid var(--border);
      transition: border-color 0.15s;
    }
    .header-avatar:hover { border-color: var(--teal); }
    .header-avatar-img {
      width: 100%;
      height: 100%;
      object-fit: cover;
    }
    .header-avatar-placeholder {
      width: 100%;
      height: 100%;
      background: #78716C;
      color: white;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 0.7rem;
      font-weight: 700;
    }

    /* === Main panels === */
    .main-panels {
      flex: 1;
      display: grid;
      grid-template-columns: 1fr 6px 1fr;
      min-height: 0;
      overflow: hidden;
    }

    /* When no workspaces, chat takes full width */
    .session-layout:not(.workspace-mode) .main-panels {
      grid-template-columns: 1fr;
    }

    .session-layout.drawer-pinned .main-panels {
      grid-template-columns: 1fr 6px 1fr;
    }

    @media (min-width: 1440px) {
      .session-layout.drawer-pinned .main-panels {
        grid-template-columns: 1fr 6px 220px 1fr;
      }
    }

    /* === Panel resizer handle === */
    .panel-resizer {
      width: 6px;
      cursor: col-resize;
      background: var(--border);
      transition: background 0.15s;
      position: relative;
      z-index: 10;
    }
    .panel-resizer:hover,
    .panel-resizer:active {
      background: var(--teal, #2dd4bf);
    }

    /* === Workspace empty state === */
    .workspace-empty-state {
      display: none;
    }

    /* === Chat panel === */
    .chat-panel {
      display: flex;
      flex-direction: column;
      min-height: 0;
      background: var(--bg-surface);
      border-right: 1px solid var(--border);
    }

    /* Tab bar */
    .chat-tab-bar {
      display: flex;
      gap: 0;
      padding: 0 1rem;
      border-bottom: 1px solid var(--border);
      background: var(--bg-surface);
      overflow-x: auto;
      flex-shrink: 0;
    }
    .chat-tab {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      padding: 0.6rem 1rem;
      border: none;
      background: none;
      cursor: pointer;
      font-size: 0.825rem;
      color: var(--text-secondary);
      border-bottom: 2px solid transparent;
      margin-bottom: -1px;
      white-space: nowrap;
      transition: color 0.15s, border-color 0.15s;
    }
    .chat-tab:hover { color: var(--text-primary); }
    .chat-tab.active {
      color: var(--text-primary);
      font-weight: 500;
      border-bottom-color: var(--teal);
    }
    .chat-tab.stopped { opacity: 0.45; }
    .tab-select-btn {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      border: none;
      background: none;
      cursor: pointer;
      padding: 0;
      color: inherit;
      font: inherit;
    }
    .tab-close-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 1.1rem;
      height: 1.1rem;
      border: none;
      background: none;
      cursor: pointer;
      font-size: 0.9rem;
      color: var(--text-secondary);
      border-radius: 3px;
      opacity: 0;
      transition: opacity 0.15s, background 0.15s, color 0.15s;
      margin-left: 0.2rem;
      padding: 0;
      line-height: 1;
    }
    .chat-tab:hover .tab-close-btn { opacity: 1; }
    .tab-close-btn:hover {
      background: var(--border);
      color: var(--text-primary);
    }
    .tab-label { font-size: 0.825rem; }
    .tab-typing {
      font-size: 0.75rem;
      color: var(--teal);
      animation: pulse 1.2s ease-in-out infinite;
    }

    /* Chat rail */
    .dt-chat-body {
      flex: 1;
      min-height: 0;
      display: flex;
      overflow: hidden;
      position: relative;
    }
    .dt-chat-main {
      flex: 1;
      min-width: 0;
      min-height: 0;
      display: flex;
      flex-direction: column;
      background: var(--bg-surface);
    }
    .chat-rail {
      width: 248px;
      min-width: 220px;
      max-width: 280px;
      border-right: 1px solid var(--border);
      background: color-mix(in srgb, var(--bg-shelf) 72%, var(--bg-surface));
      padding: 0.8rem 0.65rem;
      flex-shrink: 0;
      display: flex;
      flex-direction: column;
      min-height: 0;
      transition: width 160ms ease, min-width 160ms ease, padding 160ms ease, opacity 120ms ease;
    }
    .chat-rail.is-collapsed {
      width: 0;
      min-width: 0;
      max-width: 0;
      padding-left: 0;
      padding-right: 0;
      opacity: 0;
      border-right: 0;
      pointer-events: none;
      overflow: hidden;
    }
    .chat-rail-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.5rem;
      margin-bottom: 0.65rem;
      padding: 0 0.1rem;
    }
    .chat-rail-title {
      font-size: 0.68rem;
      font-weight: 650;
      color: var(--text-secondary);
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .chat-new-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 1.35rem;
      height: 1.35rem;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: var(--bg-surface);
      color: var(--text-secondary);
      cursor: pointer;
      font-size: 0.85rem;
      line-height: 1;
      transition: color 0.15s, border-color 0.15s, background 0.15s;
    }
    .chat-new-btn:hover {
      color: var(--text-primary);
      border-color: var(--text-secondary);
      background: var(--bg-hover);
    }
    .chat-rail-collapse-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 1.35rem;
      height: 1.35rem;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: transparent;
      color: var(--text-muted);
      cursor: pointer;
      font-size: 1rem;
      line-height: 1;
      transition: color 0.15s, border-color 0.15s, background 0.15s;
    }
    .chat-rail-collapse-btn:hover {
      color: var(--text-primary);
      border-color: var(--text-secondary);
      background: var(--bg-hover);
    }
    .chat-rail-tab {
      width: 34px;
      flex: 0 0 34px;
      border: 0;
      border-right: 1px solid var(--border);
      background: color-mix(in srgb, var(--bg-shelf) 68%, var(--bg-surface));
      color: var(--text-secondary);
      cursor: pointer;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: flex-start;
      gap: 8px;
      padding: 12px 0;
      transition: background 0.15s, color 0.15s;
    }
    .chat-rail-tab:hover {
      background: var(--bg-hover);
      color: var(--text-primary);
    }
    .chat-rail-tab span {
      writing-mode: vertical-rl;
      text-transform: uppercase;
      font-size: 0.66rem;
      line-height: 1;
      font-weight: 760;
      letter-spacing: 0;
    }
    .chat-rail-tab strong {
      min-width: 18px;
      min-height: 18px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: var(--bg-surface);
      color: var(--text-muted);
      font-size: 0.68rem;
      font-variant-numeric: tabular-nums;
    }
    .chat-rail-tab:not(.is-collapsed) {
      display: none;
    }
    .chat-list {
      display: flex;
      flex-direction: column;
      gap: 0.4rem;
      overflow-y: auto;
      min-height: 0;
      padding-right: 0.15rem;
      scrollbar-width: thin;
    }
    .chat-row {
      position: relative;
      display: flex;
      width: 100%;
      min-height: 4.35rem;
      border: 1px solid var(--border);
      border-radius: 7px;
      background: var(--bg-surface);
      overflow: hidden;
      transition: border-color 0.15s, background 0.15s, box-shadow 0.15s;
    }
    .chat-row:hover {
      border-color: color-mix(in srgb, var(--text-secondary) 42%, var(--border));
      background: var(--bg-hover);
    }
    .chat-row.active {
      border-color: var(--teal);
      box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--teal) 50%, transparent);
    }
    .chat-row.is-dragging {
      opacity: 0.58;
      box-shadow: 0 0.35rem 1rem rgba(0, 0, 0, 0.12);
    }
    .chat-drag-handle {
      position: absolute;
      inset: 0 auto 0 0;
      width: 1.4rem;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      color: var(--text-muted);
      cursor: grab;
      user-select: none;
      font-size: 0.72rem;
      line-height: 1;
      z-index: 2;
    }
    .chat-drag-handle:active {
      cursor: grabbing;
    }
    .chat-open-btn {
      display: grid;
      grid-template-columns: minmax(0, 1fr);
      gap: 0.5rem;
      align-items: start;
      width: 100%;
      min-width: 0;
      border: 0;
      background: transparent;
      color: inherit;
      cursor: pointer;
      text-align: left;
      padding: 0.65rem 2.6rem 0.65rem 1.75rem;
      font: inherit;
    }
    .chat-row-main {
      display: flex;
      flex-direction: column;
      gap: 0.18rem;
      min-width: 0;
    }
    .chat-row-title {
      color: var(--text-primary);
      font-size: 0.78rem;
      font-weight: 600;
      line-height: 1.15;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .chat-row-preview {
      color: var(--text-muted);
      font-size: 0.68rem;
      line-height: 1.2;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .chat-row-meta {
      display: flex;
      flex-direction: row;
      align-items: center;
      justify-content: space-between;
      gap: 0.25rem;
      color: var(--text-muted);
      font-size: 0.64rem;
      font-family: var(--font-mono);
      white-space: nowrap;
    }
    .chat-row-agent {
      max-width: 9rem;
      overflow: hidden;
      text-overflow: ellipsis;
      color: var(--text-secondary);
      font-family: var(--font-body);
      font-size: 0.64rem;
      font-weight: 600;
      letter-spacing: 0;
    }
    .chat-archive-btn {
      position: absolute;
      top: 0.25rem;
      right: 0.25rem;
      width: 1rem;
      height: 1rem;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: var(--bg-surface);
      color: var(--text-muted);
      cursor: pointer;
      opacity: 0;
      font-size: 0.72rem;
      line-height: 1;
      transition: opacity 0.15s, color 0.15s, border-color 0.15s, background 0.15s;
    }
    .chat-row:hover .chat-archive-btn {
      opacity: 1;
    }
    .chat-archive-btn:hover {
      color: var(--text-primary);
      border-color: var(--text-secondary);
      background: var(--bg-hover);
    }
    .chat-edit-btn {
      position: absolute;
      right: 0.25rem;
      bottom: 0.25rem;
      height: 1.05rem;
      padding: 0 0.32rem;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: var(--bg-surface);
      color: var(--text-muted);
      cursor: pointer;
      opacity: 0;
      font-size: 0.6rem;
      line-height: 1;
      z-index: 3;
      transition: opacity 0.15s, color 0.15s, border-color 0.15s, background 0.15s;
    }
    .chat-row:hover .chat-edit-btn,
    .chat-row:focus-within .chat-edit-btn {
      opacity: 1;
    }
    .chat-edit-btn:hover {
      color: var(--text-primary);
      border-color: var(--text-secondary);
      background: var(--bg-hover);
    }
    .chat-title-form {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto auto;
      gap: 0.35rem;
      align-items: center;
      width: 100%;
      padding: 0.62rem 0.45rem 0.62rem 1.75rem;
    }
    .chat-title-input {
      min-width: 0;
      width: 100%;
      height: 1.7rem;
      border: 1px solid color-mix(in srgb, var(--text-secondary) 34%, var(--border));
      border-radius: 5px;
      background: var(--bg-surface);
      color: var(--text-primary);
      padding: 0 0.45rem;
      font: inherit;
      font-size: 0.75rem;
    }
    .chat-title-input:focus {
      outline: none;
      border-color: var(--teal);
      box-shadow: 0 0 0 2px color-mix(in srgb, var(--teal) 18%, transparent);
    }
    .chat-title-save,
    .chat-title-cancel {
      height: 1.7rem;
      border: 1px solid var(--border);
      border-radius: 5px;
      background: var(--bg-surface);
      color: var(--text-secondary);
      cursor: pointer;
      font-size: 0.68rem;
      padding: 0 0.45rem;
    }
    .chat-title-cancel {
      width: 1.7rem;
      padding: 0;
    }
    .chat-title-save:hover,
    .chat-title-cancel:hover {
      color: var(--text-primary);
      border-color: var(--text-secondary);
      background: var(--bg-hover);
    }
    .chat-empty {
      display: flex;
      align-items: center;
      color: var(--text-muted);
      font-size: 0.75rem;
      min-height: 3rem;
      padding: 0 0.25rem;
    }

    @media (max-width: 940px) {
      .dt-chat-body {
        flex-direction: column;
      }
      .chat-rail {
        width: 100%;
        max-width: none;
        min-width: 0;
        max-height: 14rem;
        border-right: none;
        border-bottom: 1px solid var(--border);
      }
      .chat-list {
        padding-right: 0;
      }
    }

    /* Workspace tab bar */
    .workspace-tab-bar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 0.5rem;
      border-bottom: 1px solid var(--border);
      background: var(--bg-surface);
      flex-shrink: 0;
    }
    .workspace-tabs {
      display: flex;
      gap: 0;
      overflow-x: auto;
    }
    .workspace-tab {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      padding: 0.5rem 0.75rem;
      border: none;
      background: none;
      cursor: pointer;
      font-size: 0.825rem;
      color: var(--text-secondary);
      border-bottom: 2px solid transparent;
      margin-bottom: -1px;
      white-space: nowrap;
      transition: color 0.15s, border-color 0.15s;
    }
    .workspace-tab:hover { color: var(--text-primary); }
    .workspace-tab.active {
      color: var(--text-primary);
      font-weight: 500;
      border-bottom-color: var(--teal);
    }
    .workspace-tab-label { font-size: 0.825rem; }
    .workspace-tab-close {
      font-size: 0.7rem;
      opacity: 0.4;
      cursor: pointer;
      margin-left: 0.25rem;
      transition: opacity 0.15s;
    }
    .workspace-tab-close:hover { opacity: 1; }
    .workspace-tab-activity {
      display: flex;
      align-items: center;
      gap: 0.3rem;
    }
    .workspace-tab-pulse {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: var(--teal);
      animation: pulse-dot 1.2s ease-in-out infinite;
    }
    .workspace-tab-badge {
      font-size: 0.65rem;
      font-weight: 600;
      color: var(--teal);
      background: var(--teal-dim);
      padding: 0.1rem 0.35rem;
      border-radius: 8px;
      line-height: 1;
      font-family: var(--font-mono);
    }
    .workspace-tab-actions {
      display: flex;
      align-items: center;
      gap: 0.25rem;
    }
    .workspace-tab-toggle-chat {
      padding: 0.35rem 0.75rem;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: none;
      cursor: pointer;
      font-size: 0.8rem;
      color: var(--text-secondary);
      transition: color 0.15s, border-color 0.15s;
    }
    .workspace-tab-toggle-chat:hover { color: var(--text-primary); border-color: var(--text-muted); }
    .workspace-tab-toggle-chat.active {
      color: var(--text-primary);
      border-color: var(--teal);
    }
    .workspace-add-picker { position: relative; }
    .workspace-add-btn {
      padding: 0.35rem 0.6rem;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: none;
      cursor: pointer;
      font-size: 0.9rem;
      color: var(--text-secondary);
      line-height: 1;
      transition: color 0.15s, border-color 0.15s;
    }
    .workspace-add-btn:hover { color: var(--text-primary); border-color: var(--text-muted); }
    .workspace-picker-dropdown {
      position: absolute;
      top: 100%;
      right: 0;
      margin-top: 0.25rem;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: 6px;
      box-shadow: var(--shadow-lg);
      z-index: 100;
      min-width: 140px;
    }
    .workspace-picker-item {
      display: block;
      width: 100%;
      padding: 0.5rem 0.75rem;
      border: none;
      background: none;
      cursor: pointer;
      font-size: 0.825rem;
      color: var(--text-secondary);
      text-align: left;
      transition: background 0.1s, color 0.1s;
    }
    .workspace-picker-item:hover {
      background: var(--bg-hover);
      color: var(--text-primary);
    }
    /* Workspace panel collapse */
    .workspace-panel-wrapper {
      flex: 1;
      min-height: 0;
      overflow: hidden;
      transition: flex 0.2s ease;
    }
    .workspace-panel-wrapper.is-collapsed {
      flex: 0;
      overflow: hidden;
    }

    /* Workspace overlay — slides in from right like agent drawer */
    .workspace-overlay {
      position: fixed;
      right: 0;
      top: 52px;
      bottom: 0;
      width: 560px;
      background: var(--bg-surface);
      border-left: 1px solid var(--border);
      box-shadow: -8px 0 24px rgba(28, 25, 23, 0.08);
      transform: translateX(100%);
      transition: transform 0.25s ease;
      z-index: 25;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    .workspace-overlay.is-open {
      transform: translateX(0);
    }
    .workspace-overlay-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0.5rem 0.75rem;
      border-bottom: 1px solid var(--border);
      background: var(--bg-surface);
      flex-shrink: 0;
    }
    .workspace-overlay-title {
      font-size: 0.85rem;
      font-weight: 600;
      color: var(--text-primary);
    }
    .workspace-overlay-actions {
      display: flex;
      align-items: center;
      gap: 0.35rem;
    }
    .workspace-overlay-btn {
      padding: 0.3rem 0.6rem;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: none;
      cursor: pointer;
      font-size: 0.75rem;
      color: var(--text-secondary);
      transition: color 0.15s, border-color 0.15s, background 0.15s;
    }
    .workspace-overlay-btn:hover {
      color: var(--text-primary);
      border-color: var(--text-muted);
      background: var(--bg-hover);
    }
    .workspace-overlay-btn.pin-btn:hover {
      color: var(--teal);
      border-color: var(--teal);
    }
    .workspace-overlay-close {
      width: 26px;
      height: 26px;
      border-radius: 50%;
      border: 1px solid var(--border);
      background: none;
      cursor: pointer;
      font-size: 0.9rem;
      color: var(--text-secondary);
      display: flex;
      align-items: center;
      justify-content: center;
      transition: background 0.15s, color 0.15s;
    }
    .workspace-overlay-close:hover {
      background: var(--bg-hover);
      color: var(--text-primary);
    }
    .workspace-overlay-body {
      flex: 1;
      min-height: 0;
      overflow: hidden;
    }
    .workspace-overlay-backdrop {
      position: fixed;
      inset: 0;
      background: rgba(28, 25, 23, 0.08);
      z-index: 24;
      opacity: 0;
      pointer-events: none;
      transition: opacity 0.25s ease;
    }
    .workspace-overlay-backdrop.is-visible {
      opacity: 1;
      pointer-events: auto;
    }

    /* Chat feed */
    .chat-feed {
      flex: 1;
      overflow-y: auto;
      max-width: 800px;
      margin: 0 auto;
      padding: 2rem;
      width: 100%;
    }
    .chat-empty {
      display: flex;
      align-items: flex-start;
      justify-content: center;
      padding-top: 30%;
      height: 100%;
      color: var(--text-muted);
      font-size: 0.9rem;
    }
    .empty-state {
      text-align: center;
      padding: 2rem;
    }
    .empty-state-icon {
      font-size: 3rem;
      font-weight: 300;
      color: var(--teal);
      opacity: 0.5;
      margin-bottom: 1rem;
      font-family: var(--font-body);
    }
    .empty-state-title {
      font-size: 1.25rem;
      font-weight: 600;
      color: var(--text-primary);
      margin-bottom: 0.5rem;
    }
    .empty-state-hint {
      font-size: 0.85rem;
      color: var(--text-muted);
    }

    .message-wrapper {
      margin-bottom: 1rem;
    }
    .message {
      display: flex;
      gap: 0.75rem;
      padding: 0.5rem 0;
    }
    .message-avatar {
      width: 28px;
      height: 28px;
      border-radius: 50%;
      flex-shrink: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 0.7rem;
      font-weight: 700;
      color: white;
      margin-top: 0.1rem;
    }
    .avatar-assistant { background: var(--teal); }
    .avatar-user { background: #78716C; }
    .avatar-agent-msg { background: #B07640; }
    .message-sender-label {
      font-size: 0.7rem;
      color: var(--teal);
      margin-bottom: 2px;
    }
    .message-from-agent .message-content {
      border-left: 2px solid var(--teal);
      padding-left: 8px;
    }
    .avatar-img {
      object-fit: cover;
      border-radius: 50%;
    }
    .message-content {
      flex: 1;
      min-width: 0;
    }
    .message-assistant .message-content {
      border-left: 2px solid var(--teal);
      padding-left: 0.75rem;
    }
    .message-user .message-content {
      border-left: 2px solid var(--border-active);
      padding-left: 0.75rem;
    }
    .message.streaming .message-body::after {
      content: '';
      display: inline-block;
      width: 6px;
      height: 14px;
      background: var(--teal);
      border-radius: 1px;
      margin-left: 2px;
      animation: blink 0.8s step-end infinite;
    }

    /* Welcome card — entrance, shimmer, typewriter caret, auto-dim, watermark */
    .welcome-card {
      position: relative;
      border-radius: 12px;
      padding: 0.85rem 1.1rem 0.95rem;
      background:
        linear-gradient(135deg,
          color-mix(in srgb, var(--teal) 7%, transparent) 0%,
          color-mix(in srgb, var(--teal) 2%, transparent) 60%,
          transparent 100%);
      border: 1px solid color-mix(in srgb, var(--teal) 22%, var(--border));
      overflow: hidden;
      outline: none;
      animation: welcome-enter 420ms cubic-bezier(.2,.8,.2,1) both;
      transition: opacity .35s ease, transform .15s ease, box-shadow .15s ease;
    }
    .welcome-card.welcome-typed {
      animation: welcome-dim 1.6s ease-out 8s forwards;
    }
    .welcome-card.welcome-already-shown,
    .welcome-card.welcome-already-shown::before,
    .welcome-card.welcome-already-shown .welcome-pill-dot {
      animation: none !important;
    }
    .welcome-card.welcome-already-shown {
      opacity: 0.55;
    }
    .welcome-card:hover,
    .welcome-card:focus-within {
      opacity: 1 !important;
      transform: translateY(-1px);
      box-shadow: 0 4px 18px rgba(0,0,0,.07);
    }
    .welcome-card::before {
      content: '';
      position: absolute;
      inset: 0;
      background: linear-gradient(
        120deg,
        transparent 30%,
        color-mix(in srgb, var(--teal) 18%, transparent) 50%,
        transparent 70%);
      transform: translateX(-100%);
      pointer-events: none;
      animation: welcome-shimmer 1.4s ease-out .15s 1 both;
    }
    .welcome-pill {
      display: inline-flex;
      align-items: center;
      gap: .35rem;
      font-size: .62rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: .06em;
      color: var(--teal);
      padding: .15rem .55rem;
      border-radius: 999px;
      background: color-mix(in srgb, var(--teal) 12%, transparent);
      margin-bottom: .55rem;
      position: relative;
      z-index: 1;
    }
    .welcome-pill-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: var(--teal);
      box-shadow: 0 0 0 0 color-mix(in srgb, var(--teal) 60%, transparent);
      animation: welcome-pulse 1.6s ease-out 3 both;
    }
    .welcome-body {
      position: relative;
      z-index: 1;
    }
    .welcome-body p:first-child { margin-top: 0; }
    .welcome-body p:last-child  { margin-bottom: 0; }
    .welcome-watermark {
      position: absolute;
      bottom: -1.1rem;
      right: 0.15rem;
      font-size: 5rem;
      line-height: 1;
      font-weight: 700;
      color: var(--teal);
      opacity: .045;
      pointer-events: none;
      user-select: none;
    }
    .welcome-caret {
      display: inline-block;
      width: 6px;
      height: 0.95em;
      background: var(--teal);
      vertical-align: text-bottom;
      margin-left: 1px;
      animation: welcome-blink .8s step-end infinite;
    }

    @keyframes welcome-enter {
      from { opacity: 0; transform: translateY(8px); }
      to   { opacity: 1; transform: translateY(0); }
    }
    @keyframes welcome-dim {
      to { opacity: 0.55; }
    }
    @keyframes welcome-shimmer {
      to { transform: translateX(100%); }
    }
    @keyframes welcome-pulse {
      0%   { box-shadow: 0 0 0 0 color-mix(in srgb, var(--teal) 60%, transparent); }
      70%  { box-shadow: 0 0 0 8px color-mix(in srgb, var(--teal) 0%,  transparent); }
      100% { box-shadow: 0 0 0 0 color-mix(in srgb, var(--teal) 0%,  transparent); }
    }
    @keyframes welcome-blink {
      50% { opacity: 0; }
    }
    @media (prefers-reduced-motion: reduce) {
      .welcome-card,
      .welcome-card.welcome-typed,
      .welcome-card::before,
      .welcome-pill-dot,
      .welcome-caret {
        animation: none !important;
      }
    }

    .btn-fork-from-here {
      display: inline-flex;
      align-items: center;
      gap: 0.3rem;
      padding: 0.2rem 0.5rem;
      margin-top: 0.35rem;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: none;
      cursor: pointer;
      font-size: 0.65rem;
      color: var(--text-secondary);
      opacity: 0.4;
      transition: opacity 0.15s, color 0.15s, border-color 0.15s, background 0.15s;
    }
    .message:hover .btn-fork-from-here { opacity: 1; }
    .btn-fork-from-here:hover {
      color: var(--text-primary);
      border-color: var(--text-secondary);
      background: var(--bg-hover);
    }

    .message-meta {
      margin-bottom: 0.25rem;
    }
    .message-role {
      font-size: 0.65rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--text-muted);
    }
    .message-body {
      font-size: 0.875rem;
      line-height: 1.65;
      color: var(--text-primary);
    }

    /* Tool calls */
    .tool-call {
      margin: 0.35rem 0;
    }
    .tool-call-compact {
      display: flex;
      align-items: center;
      flex-wrap: wrap;
      gap: 0.35rem;
      width: fit-content;
      max-width: 100%;
      padding: 0.35rem 0.5rem;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--bg-shelf);
      color: var(--text-secondary);
      font-size: 0.78rem;
    }
    .tool-compact-label {
      color: var(--text-muted);
      font-size: 0.72rem;
    }
    .tool-output-preview {
      flex-basis: 100%;
      max-width: 34rem;
      color: var(--text-muted);
      font-size: 0.74rem;
      line-height: 1.45;
      overflow-wrap: anywhere;
    }
    .tool-call-summary {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      cursor: pointer;
      font-size: 0.8rem;
      color: var(--text-secondary);
      padding: 0.25rem 0;
      list-style: none;
    }
    .tool-call-summary::-webkit-details-marker { display: none; }
    .tool-call-summary::before {
      content: '▸';
      font-size: 0.65rem;
      color: var(--text-muted);
      transition: transform 0.15s;
    }
    details[open] > .tool-call-summary::before { transform: rotate(90deg); }
    .tool-call-summary:hover { color: var(--text-primary); }
    .tool-name {
      font-family: var(--font-mono);
      font-weight: 500;
    }
    .tool-status { font-size: 0.75rem; }
    .tool-status-ok { color: var(--green); }
    .tool-status-error { color: var(--red); }
    .tool-status-pending { color: var(--text-muted); }

    .tool-call-detail {
      padding: 0.75rem;
      margin: 0.35rem 0;
      background: var(--bg-mid);
      border-radius: var(--radius);
      border: 1px solid var(--border);
    }
    .tool-args-code, .tool-output pre {
      font-family: var(--font-mono);
      font-size: 0.75rem;
      line-height: 1.5;
      white-space: pre-wrap;
      word-break: break-word;
      color: var(--text-secondary);
    }
    .tool-output { margin-top: 0.5rem; padding-top: 0.5rem; border-top: 1px solid var(--border); }

    /* Thinking blocks */
    .thinking-block { margin: 0.35rem 0; }
    .thinking-summary {
      font-size: 0.8rem;
      color: var(--text-muted);
      cursor: pointer;
      font-style: italic;
      padding: 0.2rem 0;
    }
    .thinking-content {
      padding: 0.75rem;
      background: var(--bg-mid);
      border-radius: var(--radius);
      border: 1px solid var(--border);
      margin-top: 0.25rem;
      font-size: 0.825rem;
    }
    .thinking-label {
      font-weight: 600;
      color: var(--text-secondary);
      margin-right: 0.5rem;
    }
    .thinking-action code {
      font-family: var(--font-mono);
      background: var(--bg-deep);
      padding: 0.15rem 0.4rem;
      border-radius: 3px;
      font-size: 0.8rem;
    }
    .thinking-args {
      font-family: var(--font-mono);
      font-size: 0.75rem;
      margin-top: 0.35rem;
    }

    /* Delegation cards */
    .delegation-card {
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 0.75rem 1rem;
      margin: 0.5rem 0;
      background: var(--bg-surface);
    }
    .delegation-pending { border-left: 3px solid var(--text-muted); }
    .delegation-ok { border-left: 3px solid var(--green); }
    .delegation-error { border-left: 3px solid var(--red); }
    .delegation-header {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      font-size: 0.85rem;
      font-weight: 500;
    }
    .delegation-icon { color: var(--teal); }
    .delegation-task {
      margin-top: 0.35rem;
      font-size: 0.8rem;
      color: var(--text-secondary);
    }
    .delegation-result pre {
      font-size: 0.75rem;
      font-family: var(--font-mono);
      white-space: pre-wrap;
      word-break: break-word;
      margin-top: 0.35rem;
      color: var(--text-secondary);
    }

    /* Error message */
    .message-error {
      display: flex;
      align-items: flex-start;
      gap: 0.5rem;
      padding: 0.5rem 0.75rem;
      background: var(--red-dim);
      border: 1px solid rgba(199, 92, 84, 0.2);
      border-radius: var(--radius);
      color: var(--red);
      font-size: 0.85rem;
    }
    .error-icon {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 1.2rem;
      height: 1.2rem;
      border-radius: 50%;
      background: var(--red);
      color: white;
      font-weight: 700;
      font-size: 0.7rem;
      flex-shrink: 0;
      margin-top: 0.1rem;
    }
    .error-text { line-height: 1.4; }

    /* UI block */
    .ui-block { margin: 0.5rem 0; }
    .ui-block-title {
      font-size: 0.8rem;
      font-weight: 600;
      margin-bottom: 0.35rem;
      color: var(--text-secondary);
    }
    .ui-block-fallback {
      background: var(--bg-mid);
      border-radius: var(--radius);
      border: 1px solid var(--border);
      padding: 0.75rem;
    }

    """
  end
end
