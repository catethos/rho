defmodule RhoWeb.InlineCSS do
  @moduledoc """
  Inline CSS for the Rho LiveView UI — Warm ivory editorial theme.
  Refined typography, warm backgrounds, copper accents.
  """

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

    .header-right { display: flex; align-items: center; gap: 1rem; }
    .header-tokens {
      font-family: var(--font-mono);
      font-size: 0.7rem;
      color: var(--text-muted);
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

    .btn-new-agent {
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
    .btn-new-agent:hover { background: var(--bg-hover); border-color: var(--border-active); }

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
      width: 30px;
      height: 30px;
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

    /* Thread picker */
    .thread-picker {
      display: flex;
      align-items: center;
      gap: 0;
      padding: 0 0.5rem;
      border-bottom: 1px solid var(--border);
      background: var(--bg-surface);
      flex-shrink: 0;
    }
    .thread-picker-tabs {
      display: flex;
      gap: 0;
      overflow-x: auto;
      flex: 1;
      min-width: 0;
    }
    .thread-tab {
      display: flex;
      align-items: center;
      gap: 0;
      padding: 0;
      border-bottom: 2px solid transparent;
      margin-bottom: -1px;
      white-space: nowrap;
      transition: border-color 0.15s;
    }
    .thread-tab:hover .thread-tab-close { opacity: 0.6; }
    .thread-tab.active {
      border-bottom-color: var(--teal);
    }
    .thread-tab-btn {
      display: flex;
      align-items: center;
      padding: 0.45rem 0.5rem 0.45rem 0.75rem;
      border: none;
      background: none;
      cursor: pointer;
      font-size: 0.75rem;
      color: var(--text-secondary);
      transition: color 0.15s;
    }
    .thread-tab-btn:hover { color: var(--text-primary); }
    .thread-tab.active .thread-tab-btn {
      color: var(--text-primary);
      font-weight: 500;
    }
    .thread-tab-label { font-size: 0.75rem; }
    .thread-tab-close {
      display: flex;
      align-items: center;
      justify-content: center;
      width: 1.1rem;
      height: 1.1rem;
      border: none;
      border-radius: 3px;
      background: none;
      cursor: pointer;
      font-size: 0.75rem;
      color: var(--text-secondary);
      opacity: 0;
      margin-right: 0.25rem;
      transition: opacity 0.15s, background 0.15s;
    }
    .thread-tab-close:hover {
      opacity: 1 !important;
      background: var(--bg-hover);
    }
    .thread-new-btn {
      display: flex;
      align-items: center;
      justify-content: center;
      width: 1.5rem;
      height: 1.5rem;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: none;
      cursor: pointer;
      font-size: 0.85rem;
      color: var(--text-secondary);
      flex-shrink: 0;
      margin-left: 0.25rem;
      transition: color 0.15s, border-color 0.15s, background 0.15s;
    }
    .thread-new-btn:hover {
      color: var(--text-primary);
      border-color: var(--text-secondary);
      background: var(--bg-hover);
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

    /* === Chat input === */
    .chat-input-area {
      max-width: 800px;
      margin: 0 auto;
      padding: 1rem 2rem 1.25rem;
      border-top: 1px solid var(--border);
      background: var(--bg-surface);
      flex-shrink: 0;
      width: 100%;
    }
    .chat-input-form {
      display: flex;
      align-items: flex-end;
      gap: 0.5rem;
      background: var(--bg-shelf);
      border: 1.5px solid var(--border);
      border-radius: var(--radius-lg);
      padding: 0.6rem 0.85rem;
      transition: border-color 0.2s ease, box-shadow 0.2s ease;
    }
    .chat-input-form:focus-within {
      border-color: var(--teal);
      box-shadow: 0 0 0 3px var(--teal-glow);
    }

    .chat-input-form textarea {
      flex: 1;
      border: none;
      outline: none;
      resize: none;
      font-family: var(--font-body);
      font-size: 0.875rem;
      color: var(--text-primary);
      background: transparent;
      padding: 0.25rem 0;
      min-height: 1.5rem;
      max-height: 200px;
      line-height: 1.55;
      letter-spacing: -0.006em;
    }
    .chat-input-form textarea::placeholder { color: var(--text-muted); }

    .btn-attach {
      cursor: pointer;
      font-size: 1.1rem;
      color: var(--text-muted);
      padding: 0.15rem;
      transition: color 0.15s;
      display: flex;
      align-items: center;
    }
    .btn-attach:hover { color: var(--text-secondary); }

    .btn-send {
      padding: 0.4rem 0.9rem;
      border-radius: var(--radius);
      border: none;
      background: var(--text-primary);
      color: var(--bg-surface);
      font-size: 0.8rem;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.2s ease;
      letter-spacing: -0.01em;
    }
    .btn-send:hover { background: var(--text-secondary); }
    .btn-send:disabled { opacity: 0.25; cursor: default; }

    /* Upload previews */
    .upload-previews {
      display: flex;
      gap: 0.5rem;
      padding: 0.5rem 0;
    }
    .upload-preview {
      position: relative;
      width: 60px;
      height: 60px;
      border-radius: var(--radius);
      overflow: hidden;
      border: 1px solid var(--border);
    }
    .upload-preview img { width: 100%; height: 100%; object-fit: cover; }
    .upload-remove {
      position: absolute;
      top: 2px;
      right: 2px;
      width: 18px;
      height: 18px;
      border-radius: 50%;
      border: none;
      background: rgba(0,0,0,0.5);
      color: white;
      font-size: 0.7rem;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .upload-progress {
      position: absolute;
      bottom: 0;
      left: 0;
      right: 0;
      background: rgba(0,0,0,0.5);
      color: white;
      font-size: 0.6rem;
      text-align: center;
      padding: 1px 0;
    }

    /* === Agent sidebar === */
    .agent-sidebar {
      background: var(--bg-surface);
      padding: 1rem;
      overflow-y: auto;
      border-left: 1px solid var(--border);
    }
    .sidebar-header {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      margin-bottom: 1rem;
    }
    .sidebar-header h3 {
      font-size: 0.85rem;
      font-weight: 600;
      color: var(--text-primary);
    }

    .agent-tree { display: flex; flex-direction: column; gap: 2px; }

    .agent-node { position: relative; }
    .agent-node-row {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      padding: 0.4rem 0.5rem;
      border-radius: var(--radius-sm);
      cursor: pointer;
      font-size: 0.8rem;
      transition: background 0.1s;
    }
    .agent-node-row:hover { background: var(--bg-hover); }
    .agent-node.selected > .agent-node-row {
      background: var(--teal-dim);
    }
    .agent-role {
      font-weight: 500;
      color: var(--text-primary);
    }
    .agent-step {
      font-family: var(--font-mono);
      font-size: 0.65rem;
      color: var(--text-muted);
    }
    .agent-children {
      margin-left: 1rem;
      padding-left: 0.75rem;
      border-left: 1px solid var(--border);
    }

    /* === Status dots === */
    .status-dot {
      display: inline-block;
      width: 7px;
      height: 7px;
      border-radius: 50%;
      flex-shrink: 0;
    }
    .status-idle { background: var(--text-muted); }
    .status-busy {
      background: var(--teal);
      animation: pulse 1.5s ease-in-out infinite;
    }
    .status-error { background: var(--red); }
    .status-stopped { background: var(--bg-deep); border: 1.5px solid var(--text-muted); }
    .status-pending { background: var(--text-muted); opacity: 0.5; }
    .status-ok { background: var(--green); }

    /* Pending response indicator */
    .pending-indicator {
      color: var(--text-muted);
      font-size: 1.25rem;
      line-height: 1;
    }
    .pending-dots span {
      animation: pendingDot 1.4s ease-in-out infinite;
      opacity: 0.2;
    }
    .pending-dots span:nth-child(2) { animation-delay: 0.2s; }
    .pending-dots span:nth-child(3) { animation-delay: 0.4s; }
    @keyframes pendingDot {
      0%, 80%, 100% { opacity: 0.2; }
      40% { opacity: 1; }
    }
    .pending-step {
      display: inline-block;
      margin-left: 0.5rem;
      font-size: 0.7rem;
      color: var(--text-muted);
      vertical-align: middle;
    }

    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.35; }
    }
    @keyframes blink {
      50% { opacity: 0; }
    }

    /* === Badge === */
    .badge {
      display: inline-flex;
      align-items: center;
      padding: 0.1rem 0.5rem;
      border-radius: 10px;
      font-size: 0.65rem;
      font-weight: 600;
      background: #e8e8e8;
      color: var(--text-secondary);
    }
    .badge-agent {
      font-family: var(--font-mono);
      font-size: 0.6rem;
    }
    .badge-depth {
      font-family: var(--font-mono);
      font-size: 0.55rem;
    }

    /* === Agent drawer === */
    .agent-drawer {
      position: fixed;
      right: 0;
      top: 0;
      bottom: 0;
      width: 380px;
      background: var(--bg-surface);
      border-left: 1px solid var(--border);
      box-shadow: -8px 0 24px rgba(28, 25, 23, 0.06);
      transform: translateX(100%);
      transition: transform 0.2s ease;
      z-index: 30;
      overflow-y: auto;
    }
    .agent-drawer.open { transform: translateX(0); }

    @media (min-width: 1440px) {
      .session-layout.drawer-pinned .agent-drawer {
        position: static;
        transform: none;
        box-shadow: none;
      }
    }

    .drawer-content { padding: 1.25rem; }
    .drawer-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 1rem;
    }
    .drawer-title {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    .drawer-title h3 {
      font-size: 1rem;
      font-weight: 600;
    }
    .drawer-close {
      width: 28px;
      height: 28px;
      border-radius: 50%;
      border: 1px solid var(--border);
      background: var(--bg-surface);
      color: var(--text-secondary);
      font-size: 1rem;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: background 0.15s;
    }
    .drawer-close:hover { background: var(--bg-hover); }

    .drawer-meta { margin-bottom: 1rem; }
    .meta-row {
      display: flex;
      justify-content: space-between;
      padding: 0.4rem 0;
      font-size: 0.825rem;
      border-bottom: 1px solid var(--border);
    }
    .meta-label { color: var(--text-muted); font-weight: 500; }

    .drawer-tape h4 { font-size: 0.85rem; font-weight: 600; margin-bottom: 0.5rem; }
    .tape-entry {
      padding: 0.4rem 0;
      border-bottom: 1px solid var(--border);
      font-size: 0.8rem;
    }
    .tape-type {
      display: inline-block;
      font-size: 0.65rem;
      font-weight: 600;
      text-transform: uppercase;
      color: var(--text-muted);
      margin-right: 0.5rem;
    }
    .tape-content { color: var(--text-secondary); }
    .tape-empty { color: var(--text-muted); font-size: 0.825rem; padding: 1rem 0; }

    /* === Modal === */
    .modal-overlay {
      position: fixed;
      inset: 0;
      background: rgba(28, 25, 23, 0.15);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 50;
      backdrop-filter: blur(6px);
    }
    .modal-dialog {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      padding: 1.5rem;
      min-width: 320px;
      max-width: 480px;
      box-shadow: var(--shadow-lg);
    }
    .modal-dialog h3 {
      font-size: 1.1rem;
      font-weight: 600;
      margin-bottom: 1rem;
    }
    .agent-parent-picker {
      margin-bottom: 1rem;
    }
    .agent-parent-label {
      display: block;
      font-size: 0.8rem;
      color: var(--text-secondary);
      margin-bottom: 0.35rem;
    }
    .agent-parent-list {
      display: flex;
      flex-wrap: wrap;
      gap: 0.4rem;
    }
    .agent-parent-btn {
      padding: 0.35rem 0.75rem;
      border-radius: var(--radius);
      border: 1px solid var(--border);
      background: var(--bg-surface);
      color: var(--text-primary);
      font-size: 0.8rem;
      cursor: pointer;
      transition: all 0.15s;
    }
    .agent-parent-btn:hover {
      border-color: var(--teal);
      color: var(--teal);
    }
    .agent-parent-btn.active {
      border-color: var(--teal);
      background: var(--teal-dim);
      color: var(--teal);
      font-weight: 500;
    }
    .agent-role-list {
      margin-bottom: 1rem;
    }
    .agent-role-label {
      display: block;
      font-size: 0.8rem;
      color: var(--text-secondary);
      margin-bottom: 0.35rem;
    }
    .agent-role-buttons {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
    }
    .agent-role-btn {
      padding: 0.5rem 1rem;
      border-radius: var(--radius);
      border: 1px solid var(--border);
      background: var(--bg-surface);
      color: var(--text-primary);
      font-size: 0.85rem;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.15s;
    }
    .agent-role-btn:hover {
      border-color: var(--teal);
      color: var(--teal);
      background: var(--teal-dim);
    }
    .modal-cancel {
      padding: 0.4rem 1rem;
      border-radius: var(--radius);
      border: 1px solid var(--border);
      background: none;
      color: var(--text-secondary);
      font-size: 0.85rem;
      cursor: pointer;
    }

    /* === Signal timeline === */
    .signal-timeline {
      border-top: 1px solid var(--border);
      background: var(--bg-surface);
      flex-shrink: 0;
    }
    .signal-timeline.collapsed { }
    .timeline-toggle {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding: 0.4rem 1.5rem;
      width: 100%;
      border: none;
      background: none;
      cursor: pointer;
      font-size: 0.7rem;
      color: var(--text-muted);
      text-align: left;
    }
    .timeline-toggle:hover { color: var(--text-secondary); }
    .timeline-label { font-weight: 500; }
    .timeline-track {
      display: flex;
      gap: 3px;
      padding: 0.35rem 1.5rem 0.5rem;
      overflow-x: auto;
      max-height: 60px;
      flex-wrap: wrap;
    }
    .signal-chip {
      width: 10px;
      height: 10px;
      border-radius: 3px;
      cursor: pointer;
      opacity: 0.7;
      transition: opacity 0.1s;
    }
    .signal-chip:hover { opacity: 1; }
    .signal-blue { background: var(--blue); }
    .signal-green { background: var(--green); }
    .signal-red { background: var(--red); }
    .signal-yellow { background: var(--yellow); }
    .signal-gray { background: var(--text-muted); }

    /* === Reconnect === */
    .reconnect-banner {
      position: fixed;
      top: 0;
      left: 50%;
      transform: translateX(-50%);
      background: var(--amber);
      color: white;
      padding: 0.4rem 1.25rem;
      border-radius: 0 0 var(--radius) var(--radius);
      font-size: 0.8rem;
      font-weight: 600;
      z-index: 100;
    }

    /* === Markdown rendering === */
    .markdown-body { line-height: 1.7; letter-spacing: -0.006em; }
    .markdown-body p { margin-bottom: 0.6em; }
    .markdown-body p:last-child { margin-bottom: 0; }
    .markdown-body code {
      background: var(--bg-deep);
      padding: 0.15rem 0.4rem;
      border-radius: 4px;
      font-family: var(--font-mono);
      font-size: 0.82em;
      color: var(--teal-bright);
    }
    .markdown-body pre {
      background: var(--bg-deep);
      border: 1px solid var(--border);
      padding: 0.85rem 1rem;
      border-radius: var(--radius);
      overflow-x: auto;
      margin: 0.6rem 0;
    }
    .markdown-body pre code {
      background: none;
      padding: 0;
      font-size: 0.8rem;
      color: var(--text-primary);
    }
    .markdown-body ul, .markdown-body ol {
      padding-left: 1.5em;
      margin: 0.4em 0;
    }
    .markdown-body li { margin-bottom: 0.25em; }
    .markdown-body a { color: var(--teal-bright); text-decoration: none; font-weight: 500; }
    .markdown-body a:hover { text-decoration: underline; }
    .markdown-body h1, .markdown-body h2, .markdown-body h3 {
      margin: 0.85em 0 0.3em;
      font-weight: 600;
      color: var(--text-primary);
      letter-spacing: -0.02em;
    }
    .markdown-body blockquote {
      border-left: 3px solid var(--teal);
      padding-left: 0.85rem;
      color: var(--text-secondary);
      margin: 0.5em 0;
      font-style: italic;
    }
    .markdown-body table {
      border-collapse: collapse;
      margin: 0.6rem 0;
      font-size: 0.85rem;
    }
    .markdown-body th, .markdown-body td {
      border: 1px solid var(--border);
      padding: 0.4rem 0.65rem;
    }
    .markdown-body th {
      background: var(--bg-deep);
      font-weight: 600;
    }

    /* === JSON highlighting === */
    .json-key { color: var(--teal-bright); }
    .json-string { color: var(--green); }
    .json-number { color: var(--amber); }
    .json-bool { color: var(--violet); }
    .json-null { color: var(--text-muted); }

    /* === Images === */
    .tool-output-image { max-width: 100%; border-radius: var(--radius); margin: 0.5rem 0; }
    .message-images img { max-width: 100%; border-radius: var(--radius); margin: 0.5rem 0; }

    /* === Scrollbar === */
    ::-webkit-scrollbar { width: 5px; height: 5px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
    ::-webkit-scrollbar-thumb:hover { background: var(--border-active); }

    /* === Responsive === */
    @media (max-width: 1024px) {
      .main-panels { grid-template-columns: 1fr; }
      .agent-sidebar { display: none; }
      .signal-timeline { display: none; }
    }

    /* sr-only */
    .sr-only {
      position: absolute;
      width: 1px;
      height: 1px;
      padding: 0;
      margin: -1px;
      overflow: hidden;
      clip: rect(0,0,0,0);
      border: 0;
    }

    /* === LiveRender utility classes === */
    [data-lr-ui] .flex { display: flex; }
    [data-lr-ui] .flex-col { flex-direction: column; }
    [data-lr-ui] .flex-row { flex-direction: row; }
    [data-lr-ui] .items-center { align-items: center; }
    [data-lr-ui] .items-start { align-items: flex-start; }
    [data-lr-ui] .justify-center { justify-content: center; }
    [data-lr-ui] .justify-between { justify-content: space-between; }
    [data-lr-ui] .gap-1 { gap: 0.25rem; }
    [data-lr-ui] .gap-2 { gap: 0.5rem; }
    [data-lr-ui] .gap-3 { gap: 0.75rem; }
    [data-lr-ui] .gap-4 { gap: 1rem; }
    [data-lr-ui] .p-2 { padding: 0.5rem; }
    [data-lr-ui] .p-3 { padding: 0.75rem; }
    [data-lr-ui] .p-4 { padding: 1rem; }
    [data-lr-ui] .px-2 { padding-left: 0.5rem; padding-right: 0.5rem; }
    [data-lr-ui] .py-1 { padding-top: 0.25rem; padding-bottom: 0.25rem; }
    [data-lr-ui] .m-0 { margin: 0; }
    [data-lr-ui] .mt-2 { margin-top: 0.5rem; }
    [data-lr-ui] .mb-2 { margin-bottom: 0.5rem; }
    [data-lr-ui] .w-full { width: 100%; }
    [data-lr-ui] .text-xs { font-size: 0.75rem; }
    [data-lr-ui] .text-sm { font-size: 0.875rem; }
    [data-lr-ui] .text-base { font-size: 1rem; }
    [data-lr-ui] .text-lg { font-size: 1.125rem; }
    [data-lr-ui] .font-medium { font-weight: 500; }
    [data-lr-ui] .font-semibold { font-weight: 600; }
    [data-lr-ui] .font-bold { font-weight: 700; }
    [data-lr-ui] .text-muted { color: var(--text-muted); }
    [data-lr-ui] .text-center { text-align: center; }
    [data-lr-ui] .rounded { border-radius: var(--radius); }
    [data-lr-ui] .rounded-lg { border-radius: var(--radius-lg); }
    [data-lr-ui] .border { border: 1px solid var(--border); }
    [data-lr-ui] .shadow { box-shadow: var(--shadow-sm); }
    [data-lr-ui] .overflow-hidden { overflow: hidden; }
    [data-lr-ui] .truncate { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    [data-lr-ui] .grid { display: grid; }
    [data-lr-ui] .grid-cols-2 { grid-template-columns: repeat(2, 1fr); }
    [data-lr-ui] .grid-cols-3 { grid-template-columns: repeat(3, 1fr); }

    /* === Debug mode === */
    .debug-active {
      background: var(--teal-dim) !important;
      border-color: var(--teal) !important;
      color: var(--teal) !important;
    }

    .session-layout.debug-mode .main-panels {
      grid-template-columns: 1fr 220px minmax(400px, 500px);
    }

    .debug-panel {
      background: var(--bg-surface);
      border-left: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }

    .debug-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0.75rem 1rem;
      border-bottom: 1px solid var(--border);
      background: var(--bg-shelf);
      flex-shrink: 0;
    }
    .debug-header h3 {
      font-size: 0.85rem;
      font-weight: 600;
      color: var(--text-primary);
    }
    .debug-meta {
      font-family: var(--font-mono);
      font-size: 0.65rem;
      color: var(--text-muted);
    }

    .debug-body {
      flex: 1;
      overflow-y: auto;
      padding: 0.75rem;
    }

    .debug-section {
      margin-bottom: 1rem;
    }
    .debug-section-title {
      font-size: 0.75rem;
      font-weight: 600;
      color: var(--text-secondary);
      text-transform: uppercase;
      letter-spacing: 0.04em;
      margin-bottom: 0.5rem;
      padding-bottom: 0.25rem;
      border-bottom: 1px solid var(--border);
    }

    .debug-tools-list {
      display: flex;
      flex-wrap: wrap;
      gap: 0.3rem;
    }
    .debug-tool-badge {
      font-family: var(--font-mono);
      font-size: 0.65rem;
      padding: 0.15rem 0.45rem;
      background: var(--teal-dim);
      color: var(--teal);
      border-radius: var(--radius-sm);
      border: 1px solid rgba(91, 181, 162, 0.15);
    }

    .debug-messages {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }

    .debug-msg {
      border: 1px solid var(--border);
      border-radius: var(--radius);
      overflow: hidden;
    }
    .debug-msg-header {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding: 0.3rem 0.6rem;
      background: var(--bg-mid);
      border-bottom: 1px solid var(--border);
    }
    .debug-msg-role {
      font-size: 0.65rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .debug-role-system { color: var(--violet); }
    .debug-role-user { color: #8b5cf6; }
    .debug-role-assistant { color: var(--teal); }
    .debug-role-unknown { color: var(--text-muted); }
    .debug-msg-idx {
      font-family: var(--font-mono);
      font-size: 0.6rem;
      color: var(--text-muted);
    }
    .debug-msg-cache {
      font-family: var(--font-mono);
      font-size: 0.55rem;
      padding: 0.05rem 0.3rem;
      background: var(--amber-dim);
      color: var(--amber);
      border-radius: 3px;
    }
    .debug-msg-details { margin-top: 0.25rem; }
    .debug-msg-summary {
      font-family: var(--font-mono);
      font-size: 0.65rem;
      color: var(--text-muted);
      cursor: pointer;
      user-select: none;
      padding: 0.15rem 0.4rem;
    }
    .debug-msg-content {
      font-family: var(--font-mono);
      font-size: 0.7rem;
      line-height: 1.5;
      padding: 0.5rem 0.6rem;
      white-space: pre-wrap;
      word-break: break-word;
      color: var(--text-secondary);
      max-height: 80vh;
      overflow-y: auto;
      margin: 0;
    }
    .debug-msg-system { border-left: 3px solid var(--violet); }
    .debug-msg-user { border-left: 3px solid #8b5cf6; }
    .debug-msg-assistant { border-left: 3px solid var(--teal); }

    .debug-empty {
      color: var(--text-muted);
      font-size: 0.85rem;
      padding: 2rem 1rem;
      text-align: center;
    }

    @media (max-width: 1200px) {
      .session-layout.debug-mode .main-panels {
        grid-template-columns: 1fr minmax(350px, 450px);
      }
      .session-layout.debug-mode .agent-sidebar { display: none; }
    }

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

    .dt-toolbar {
      display: flex;
      align-items: center;
      gap: 14px;
      padding: 0 20px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border);
      height: 52px;
      flex-shrink: 0;
    }

    .dt-title {
      font-size: 0.9375rem;
      font-weight: 600;
      color: var(--text-primary);
      letter-spacing: -0.01em;
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
      max-width: 720px;
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
      gap: 8px;
      padding: 10px 16px;
      border-bottom: 1px solid var(--border);
      height: 48px;
      flex-shrink: 0;
    }

    .dt-chat-title {
      font-size: 0.875rem;
      font-weight: 600;
      color: var(--text-primary);
    }

    .dt-chat-header .thread-picker {
      border-bottom: none;
      padding: 0;
      flex: 1;
      min-width: 0;
    }

    .dt-chat-panel .chat-feed {
      flex: 1;
      overflow-y: auto;
    }

    .dt-chat-panel .chat-input-area {
      border-top: 1px solid var(--border);
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

    /* === Auth pages (login / register) === */
    .auth-container {
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: calc(100vh - var(--nav-height));
      padding: 2rem;
      background: var(--bg-abyss);
    }

    .auth-card {
      width: 100%;
      max-width: 380px;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      padding: 2.5rem 2rem 2rem;
      box-shadow: var(--shadow-lg);
    }

    .auth-title {
      font-family: var(--font-body);
      font-size: 1.35rem;
      font-weight: 600;
      color: var(--text-primary);
      margin-bottom: 1.75rem;
      letter-spacing: -0.01em;
    }

    .auth-field {
      margin-bottom: 1.15rem;
    }

    .auth-field label {
      display: block;
      font-size: 0.8rem;
      font-weight: 500;
      color: var(--text-secondary);
      margin-bottom: 0.4rem;
      letter-spacing: 0.01em;
    }

    .auth-field input {
      width: 100%;
      padding: 0.55rem 0.75rem;
      font-family: var(--font-body);
      font-size: 0.875rem;
      color: var(--text-primary);
      background: var(--bg-shelf);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      outline: none;
      transition: border-color 0.15s;
    }

    .auth-field input:focus {
      border-color: var(--teal);
      box-shadow: 0 0 0 2px var(--teal-glow);
    }

    .auth-field input::placeholder {
      color: var(--text-muted);
    }

    .auth-button {
      width: 100%;
      padding: 0.65rem;
      margin-top: 0.5rem;
      font-family: var(--font-body);
      font-size: 0.875rem;
      font-weight: 600;
      color: #fff;
      background: var(--text-primary);
      border: none;
      border-radius: var(--radius);
      cursor: pointer;
      transition: all 0.2s ease;
      letter-spacing: -0.01em;
    }

    .auth-button:hover {
      background: var(--text-secondary);
    }

    .auth-link {
      margin-top: 1.25rem;
      text-align: center;
      font-size: 0.8rem;
      color: var(--text-muted);
    }

    .auth-link a {
      color: var(--teal);
      text-decoration: none;
      font-weight: 500;
    }

    .auth-link a:hover {
      text-decoration: underline;
    }

    .auth-error {
      font-size: 0.75rem;
      color: var(--red);
      margin-top: 0.3rem;
    }

    /* === Global Navigation === */
    .global-nav {
      position: relative;
      display: flex;
      align-items: center;
      justify-content: space-between;
      height: var(--nav-height);
      padding: 0 1.5rem;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border);
      flex-shrink: 0;
      z-index: 50;
    }
    .global-nav-left { display: flex; align-items: center; gap: 1.75rem; }
    .global-nav-logo {
      font-family: var(--font-body);
      font-size: 1.1rem;
      font-weight: 700;
      color: var(--text-primary);
      text-decoration: none;
      letter-spacing: -0.04em;
    }
    .global-nav-links { display: flex; gap: 0.15rem; }
    .global-nav-link {
      padding: 0.35rem 0.7rem;
      font-size: 0.8rem;
      font-weight: 500;
      color: var(--text-muted);
      text-decoration: none;
      border-radius: var(--radius-sm);
      transition: all 0.2s ease;
      letter-spacing: -0.01em;
    }
    .global-nav-link:hover { color: var(--text-primary); background: var(--bg-hover); }
    .global-nav-link[aria-current="page"] {
      color: var(--teal-bright);
      background: var(--teal-dim);
      font-weight: 600;
    }
    .global-nav-right { display: flex; align-items: center; gap: 0.75rem; }
    .global-nav-user { font-size: 0.75rem; color: var(--text-muted); }
    .global-nav-logout-form { margin: 0; }
    .global-nav-logout {
      background: none; border: none;
      font-family: var(--font-body);
      font-size: 0.75rem; font-weight: 500;
      color: var(--text-muted); cursor: pointer;
      padding: 0; transition: color 0.15s;
    }
    .global-nav-logout:hover { color: var(--red); }

    .org-switcher {
      display: flex; align-items: center; gap: 0.35rem;
      padding: 0.3rem 0.6rem;
      font-size: 0.8rem; font-weight: 500;
      color: var(--text-primary);
      cursor: pointer;
      border-radius: var(--radius-sm);
      transition: background 0.15s;
    }
    .org-switcher:hover { background: var(--bg-hover); }
    .org-switcher-arrow { font-size: 0.65rem; color: var(--text-muted); }

    .org-dropdown {
      position: absolute;
      top: var(--nav-height);
      left: 1.5rem;
      min-width: 220px;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      box-shadow: var(--shadow-lg);
      z-index: 100;
      padding: 0.35rem 0;
    }
    .org-dropdown-item {
      display: flex; justify-content: space-between; align-items: center;
      padding: 0.5rem 0.85rem;
      font-size: 0.8rem;
      color: var(--text-primary);
      text-decoration: none;
      transition: background 0.12s;
    }
    .org-dropdown-item:hover { background: var(--bg-hover); }
    .org-dropdown-name { font-weight: 500; }
    .org-dropdown-role { font-size: 0.7rem; color: var(--text-muted); }
    .org-dropdown-divider {
      border: none;
      border-top: 1px solid var(--border);
      margin: 0.3rem 0;
    }

    @media (max-width: 640px) {
      .global-nav-links { display: none; }
    }

    /* === Auth logo === */
    .auth-logo {
      font-family: var(--font-body);
      font-size: 1.5rem;
      font-weight: 700;
      color: var(--text-primary);
      text-align: center;
      margin-bottom: 1.5rem;
      letter-spacing: -0.04em;
    }

    /* === Page Shell (standard pages) === */
    .page-shell {
      max-width: 960px;
      margin: 0 auto;
      padding: 2rem 1.5rem;
    }

    .page-header {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      margin-bottom: 2rem;
      padding-bottom: 1.25rem;
      border-bottom: 1px solid var(--border);
    }
    .page-header-text { flex: 1; }
    .page-title {
      font-size: 1.5rem;
      font-weight: 700;
      color: var(--text-primary);
      letter-spacing: -0.02em;
    }
    .page-subtitle {
      margin-top: 0.35rem;
      font-size: 0.875rem;
      color: var(--text-secondary);
      line-height: 1.5;
    }
    .page-header-actions { display: flex; gap: 0.5rem; margin-left: 1rem; }

    /* === Shared Card === */
    .rho-card {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      padding: 1.25rem 1.5rem;
      box-shadow: var(--shadow-sm);
      transition: border-color 0.15s, box-shadow 0.15s;
    }
    .rho-card:hover {
      border-color: var(--border-active);
      box-shadow: var(--shadow-md);
    }

    /* === Empty State === */
    .empty-state {
      text-align: center;
      padding: 3rem 2rem;
      color: var(--text-muted);
      font-size: 0.9rem;
      background: var(--bg-shelf);
      border-radius: var(--radius-lg);
      border: 1px dashed var(--border);
    }

    /* === Shared Buttons === */
    .btn-primary {
      display: inline-flex; align-items: center; gap: 0.4rem;
      padding: 0.5rem 1rem;
      font-family: var(--font-body);
      font-size: 0.8rem; font-weight: 600;
      color: var(--bg-surface); background: var(--text-primary);
      border: none; border-radius: var(--radius);
      cursor: pointer; transition: all 0.2s ease;
      text-decoration: none; letter-spacing: -0.01em;
    }
    .btn-primary:hover { background: var(--text-secondary); }

    .btn-secondary {
      display: inline-flex; align-items: center; gap: 0.4rem;
      padding: 0.5rem 1rem;
      font-family: var(--font-body);
      font-size: 0.8rem; font-weight: 500;
      color: var(--text-secondary);
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      cursor: pointer; transition: all 0.15s;
      text-decoration: none;
    }
    .btn-secondary:hover { background: var(--bg-hover); border-color: var(--border-active); }

    .btn-secondary-sm {
      padding: 0.3rem 0.65rem;
      font-family: var(--font-body);
      font-size: 0.75rem; font-weight: 500;
      color: var(--text-secondary); background: var(--bg-deep);
      border: 1px solid var(--border);
      border-radius: var(--radius-sm);
      cursor: pointer; transition: all 0.15s;
      white-space: nowrap;
    }
    .btn-secondary-sm:hover { background: var(--bg-surface); }
    .btn-danger-sm {
      padding: 0.3rem 0.65rem;
      font-family: var(--font-body);
      font-size: 0.75rem; font-weight: 500;
      color: var(--red); background: var(--red-dim);
      border: 1px solid rgba(229,83,75,0.15);
      border-radius: var(--radius-sm);
      cursor: pointer; transition: all 0.15s;
    }
    .btn-danger-sm:hover { background: rgba(229,83,75,0.15); }

    /* === Forms === */
    .form-card {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 1.5rem;
      margin-bottom: 1rem;
    }
    .form-card-title {
      font-size: 1rem; font-weight: 600;
      color: var(--text-primary);
      margin-bottom: 1rem;
    }
    .form-group {
      margin-bottom: 1rem;
    }
    .form-label {
      display: block;
      font-size: 0.8rem; font-weight: 600;
      color: var(--text-primary);
      margin-bottom: 0.35rem;
    }
    .form-hint {
      font-size: 0.75rem;
      color: var(--text-muted);
      margin-bottom: 0.35rem;
    }
    .form-input {
      display: block;
      width: 100%;
      padding: 0.5rem 0.7rem;
      font-family: var(--font-body);
      font-size: 0.85rem;
      color: var(--text-primary);
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-sm);
      transition: border-color 0.15s;
    }
    .form-input:focus {
      outline: none;
      border-color: var(--teal);
      box-shadow: 0 0 0 2px rgba(91, 138, 186, 0.15);
    }
    .form-input:disabled {
      background: var(--bg-hover);
      color: var(--text-muted);
      cursor: not-allowed;
    }
    textarea.form-input {
      resize: vertical;
      min-height: 80px;
    }
    .form-error {
      font-size: 0.75rem;
      color: var(--red);
      margin-top: 0.25rem;
    }
    .form-code {
      font-family: var(--font-mono);
      font-size: 0.8rem;
      color: var(--text-muted);
    }
    .form-actions {
      margin-top: 1.25rem;
    }
    .danger-zone {
      border-color: rgba(229,83,75,0.3);
    }
    .danger-title {
      font-size: 0.95rem; font-weight: 600;
      color: var(--red);
      margin-bottom: 0.5rem;
    }
    .danger-desc {
      font-size: 0.8rem;
      color: var(--text-muted);
      margin-bottom: 1rem;
    }
    .btn-danger {
      padding: 0.5rem 1rem;
      font-family: var(--font-body);
      font-size: 0.8rem; font-weight: 600;
      color: #fff; background: var(--red);
      border: none; border-radius: var(--radius);
      cursor: pointer; transition: background 0.15s;
    }
    .btn-danger:hover { background: #a84840; }

    /* === Shared Table === */
    .rho-table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.85rem;
    }
    .rho-table thead th {
      text-align: left;
      padding: 0.6rem 0.75rem;
      font-size: 0.7rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--text-muted);
      border-bottom: 1px solid var(--border);
    }
    .rho-table tbody td {
      padding: 0.65rem 0.75rem;
      border-bottom: 1px solid var(--bg-deep);
      color: var(--text-primary);
    }
    .rho-table tbody tr:hover { background: var(--bg-shelf); }

    .skill-link {
      color: var(--teal);
      text-decoration: none;
    }
    .skill-link:hover {
      text-decoration: underline;
    }

    .skill-highlight {
      background: rgba(0, 200, 180, 0.15) !important;
      transition: background 1s ease-out;
    }

    /* === Breadcrumb === */
    .breadcrumb {
      display: flex; align-items: center; gap: 0.35rem;
      font-size: 0.8rem; color: var(--text-muted);
      margin-bottom: 1rem;
    }
    .breadcrumb a {
      color: var(--text-secondary);
      text-decoration: none;
      transition: color 0.15s;
    }
    .breadcrumb a:hover { color: var(--teal); }
    .breadcrumb-sep { color: var(--text-muted); }

    /* === Framework Pages === */
    .framework-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
      gap: 1rem;
    }
    .framework-card-top { display: flex; align-items: center; justify-content: space-between; margin-bottom: 0.5rem; }
    .framework-card-name {
      font-size: 1.05rem; font-weight: 600;
      color: var(--text-primary); text-decoration: none;
    }
    .framework-card-name:hover { color: var(--teal); }
    .framework-card-desc { font-size: 0.85rem; color: var(--text-secondary); line-height: 1.5; margin-bottom: 0.75rem; }
    .framework-card-footer { display: flex; align-items: center; justify-content: space-between; padding-top: 0.75rem; border-top: 1px solid var(--bg-deep); }
    .framework-card-date { font-size: 0.75rem; color: var(--text-muted); }
    .badge-muted { background: var(--bg-deep); color: var(--text-secondary); font-size: 0.7rem; padding: 0.2rem 0.5rem; border-radius: 999px; }
    .badge-version { background: #E0F2F1; color: #00695C; font-size: 0.65rem; font-weight: 600; padding: 0.15rem 0.45rem; border-radius: 999px; }
    .badge-default { background: #E3F2FD; color: #1565C0; font-size: 0.65rem; font-weight: 600; padding: 0.15rem 0.45rem; border-radius: 999px; }
    .badge-draft { background: #FFF3E0; color: #E65100; font-size: 0.65rem; font-weight: 600; padding: 0.15rem 0.45rem; border-radius: 999px; }
    .badge-immutable { background: var(--bg-deep); color: var(--text-muted); font-size: 0.65rem; font-weight: 600; padding: 0.15rem 0.45rem; border-radius: 999px; }
    .badge-public { background: #EDE7F6; color: #5E35B1; font-size: 0.65rem; font-weight: 600; padding: 0.15rem 0.45rem; border-radius: 999px; }

    /* === Library list view === */
    .lib-list { display: flex; flex-direction: column; gap: 0; }
    .lib-list-header { display: grid; grid-template-columns: 1fr 140px 70px 120px 170px; gap: 0.75rem; padding: 0.5rem 1rem; font-size: 0.7rem; font-weight: 600; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.04em; border-bottom: 2px solid var(--border); }
    .lib-group { border-bottom: 1px solid var(--border); }
    .lib-group summary { list-style: none; cursor: pointer; }
    .lib-group summary::-webkit-details-marker { display: none; }
    .lib-group[open] > .lib-row-primary { border-bottom: 1px dashed var(--border); }
    .lib-row { display: grid; grid-template-columns: 1fr 140px 70px 120px 170px; gap: 0.75rem; align-items: center; padding: 0.65rem 1rem; font-size: 0.85rem; color: var(--text-primary); transition: background 0.1s; }
    .lib-row:hover { background: var(--bg-deep); }
    .lib-row-version { background: var(--bg-card); }
    .lib-row-version:hover { background: var(--bg-deep); }
    .lib-version-indent { padding-left: 1.25rem; }
    .lib-col-name { display: flex; align-items: center; gap: 0.5rem; min-width: 0; }
    .lib-col-version { display: flex; align-items: center; }
    .lib-col-skills { text-align: center; color: var(--text-secondary); }
    .lib-col-updated { font-size: 0.78rem; color: var(--text-muted); }
    .lib-col-actions { display: flex; justify-content: flex-end; gap: 0.4rem; align-items: center; }
    .lib-name-link { font-weight: 500; color: var(--text-primary); text-decoration: none; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .lib-name-link:hover { color: var(--teal); }
    .fw-section { margin-bottom: 2rem; }
    .fw-section-title { font-size: 1.1rem; font-weight: 600; color: var(--text-primary); margin-bottom: 1rem; padding-bottom: 0.5rem; border-bottom: 1px solid var(--border); }
    .fw-cluster { margin-bottom: 2rem; }
    .fw-cluster-title { font-size: 1rem; font-weight: 600; color: var(--text-primary); }
    .fw-category { margin-bottom: 1.25rem; margin-left: 0.75rem; }
    .fw-category-title { font-size: 0.8rem; font-weight: 500; color: var(--text-secondary); }

    /* === Collapsible sections === */
    .fw-collapse { margin-bottom: 0.5rem; }
    .fw-collapse-summary {
      display: flex; align-items: center; gap: 0.5rem;
      cursor: pointer; list-style: none;
      padding: 0.5rem 0.25rem;
      border-radius: var(--radius);
      transition: background 0.15s;
      user-select: none;
    }
    .fw-collapse-summary:hover { background: var(--bg-hover); }
    .fw-collapse-summary::-webkit-details-marker { display: none; }
    button.fw-collapse-summary {
      width: 100%;
      background: transparent;
      border: 0;
      font: inherit;
      color: inherit;
      text-align: left;
    }

    .fw-collapse-arrow {
      display: inline-block;
      width: 0; height: 0;
      border-left: 5px solid var(--text-muted);
      border-top: 4px solid transparent;
      border-bottom: 4px solid transparent;
      transition: transform 0.15s;
      flex-shrink: 0;
    }
    details[open] > .fw-collapse-summary > .fw-collapse-arrow,
    .fw-collapse.is-open > .fw-collapse-summary > .fw-collapse-arrow {
      transform: rotate(90deg);
    }

    .fw-collapse-body { padding-left: 0.75rem; }
    .fw-collapse--nested { margin-bottom: 0.25rem; }
    .fw-collapse--nested > .fw-collapse-summary { padding: 0.35rem 0.25rem; }
    .fw-collapse--nested .fw-collapse-body { padding-left: 0.5rem; }

    /* === Diff Panel === */
    .diff-panel {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 1.25rem 1.5rem;
      margin-bottom: 1.5rem;
    }
    .diff-title {
      font-size: 0.85rem;
      font-weight: 600;
      color: var(--text-primary);
      margin: 0 0 0.75rem 0;
    }
    .diff-stats {
      display: flex;
      gap: 0.75rem;
      flex-wrap: wrap;
      margin-bottom: 1rem;
    }
    .diff-stat {
      font-size: 0.75rem;
      font-weight: 500;
      padding: 0.2rem 0.6rem;
      border-radius: 999px;
    }
    .diff-added { background: rgba(34, 139, 34, 0.1); color: #1a7a1a; }
    .diff-removed { background: rgba(200, 50, 50, 0.1); color: #b33030; }
    .diff-modified { background: rgba(194, 133, 90, 0.12); color: var(--teal-bright); }
    .diff-unchanged { background: var(--bg-deep); color: var(--text-muted); }
    .diff-section {
      margin-top: 0.75rem;
    }
    .diff-section h4 {
      font-size: 0.75rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--text-secondary);
      margin: 0 0 0.35rem 0;
    }
    .diff-section ul {
      list-style: none;
      margin: 0;
      padding: 0;
    }
    .diff-section li {
      font-size: 0.8rem;
      color: var(--text-primary);
      padding: 0.25rem 0;
    }
    .diff-section li::before {
      content: "•";
      color: var(--text-muted);
      margin-right: 0.5rem;
    }

    /* === Filter Bar === */
    .filter-bar {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      margin-bottom: 1.25rem;
    }
    .filter-select {
      appearance: none;
      -webkit-appearance: none;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-sm);
      padding: 0.4rem 2rem 0.4rem 0.75rem;
      font-size: 0.8rem;
      font-family: inherit;
      color: var(--text-primary);
      cursor: pointer;
      background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath d='M3 5l3 3 3-3' fill='none' stroke='%2357534E' stroke-width='1.5' stroke-linecap='round'/%3E%3C/svg%3E");
      background-repeat: no-repeat;
      background-position: right 0.6rem center;
    }
    .filter-select:hover { border-color: var(--border-active); }
    .filter-select:focus { outline: none; border-color: var(--teal); box-shadow: 0 0 0 2px var(--teal-dim); }
    .filter-count {
      font-size: 0.8rem;
      color: var(--text-muted);
    }

    /* === Search Bar === */
    .search-bar {
      margin-bottom: 1rem;
      display: flex;
    }
    .search-bar--inline {
      flex: 1;
      margin-bottom: 0;
    }
    .search-input {
      flex: 1;
      width: 100%;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-sm);
      padding: 0.45rem 0.75rem;
      font-size: 0.85rem;
      font-family: inherit;
      color: var(--text-primary);
    }
    .search-input::placeholder { color: var(--text-muted); }
    .search-input:hover { border-color: var(--border-active); }
    .search-input:focus { outline: none; border-color: var(--teal); box-shadow: 0 0 0 2px var(--teal-dim); }

    /* === Role Profile Styles === */
    .role-description {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 1.25rem;
    }
    .role-field {
      background: var(--bg-shelf);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 1rem 1.25rem;
    }
    .role-field-label {
      font-size: 0.7rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--text-muted);
      margin-bottom: 0.5rem;
    }
    .role-field p {
      font-size: 0.85rem;
      color: var(--text-primary);
      line-height: 1.6;
    }
    .role-field--full { grid-column: 1 / -1; }

    /* Fixed-width table columns for skill requirements */
    .rho-table th:nth-child(2),
    .rho-table td:nth-child(2) { width: 140px; text-align: center; }
    .rho-table th:nth-child(3),
    .rho-table td:nth-child(3) { width: 110px; text-align: center; }
    .rho-table th:nth-child(4),
    .rho-table td:nth-child(4) { width: 80px; text-align: center; }

    /* Card top row badges */
    .framework-card-badges { display: flex; gap: 0.4rem; align-items: center; flex-shrink: 0; }

    /* Level badge with color */
    .badge-level {
      display: inline-flex; align-items: center; justify-content: center;
      min-width: 24px; height: 24px;
      font-size: 0.75rem; font-weight: 600;
      border-radius: 6px; padding: 0 0.4rem;
    }
    .badge-level--required { background: var(--teal-dim); color: var(--teal); border: 1px solid rgba(91, 181, 162, 0.2); }
    .badge-level--optional { background: var(--bg-deep); color: var(--text-secondary); border: 1px solid var(--border); }

    /* Required dot indicator */
    .required-dot {
      display: inline-block; width: 8px; height: 8px;
      border-radius: 50%; background: var(--teal);
    }
    .required-dot--no { background: var(--bg-deep); border: 1px solid var(--border); }

    /* === Proficiency Levels === */
    .proficiency-panel { padding: 0.75rem 1.5rem; background: var(--bg-deep); border-top: 1px solid var(--border); }
    .skill-expand-arrow {
      display: inline-block;
      width: 0;
      height: 0;
      border-left: 4.5px solid var(--text-muted);
      border-top: 3.5px solid transparent;
      border-bottom: 3.5px solid transparent;
      margin-right: 0.5rem;
      transition: transform 0.15s;
      vertical-align: middle;
    }
    .skill-expanded .skill-expand-arrow {
      transform: rotate(90deg);
    }
    .proficiency-hidden { display: none; }
    .proficiency-list {
      display: grid;
      grid-template-columns: 2rem 9rem 1fr;
      gap: 0;
      align-items: baseline;
    }
    .proficiency-item {
      display: contents;
    }
    .proficiency-item > * {
      padding: 0.45rem 0;
      border-bottom: 1px solid var(--border);
    }
    .proficiency-item:last-child > * { border-bottom: none; }
    .proficiency-level { font-size: 0.7rem; font-weight: 700; color: var(--teal-bright); background: var(--teal-dim); padding: 0.2rem 0.4rem; border-radius: 4px; justify-self: start; align-self: baseline; }
    .proficiency-name { font-size: 0.8rem; font-weight: 600; color: var(--text-primary); padding-left: 0.5rem; }
    .proficiency-desc { font-size: 0.8rem; color: var(--text-secondary); line-height: 1.45; padding-left: 0.5rem; }

    /* === Command Palette === */
    .command-palette-overlay {
      position: fixed;
      inset: 0;
      background: rgba(28, 25, 23, 0.18);
      display: flex;
      align-items: flex-start;
      justify-content: center;
      padding-top: 18vh;
      z-index: 60;
      backdrop-filter: blur(6px);
    }
    .command-palette {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      width: 500px;
      max-width: 90vw;
      box-shadow: var(--shadow-lg);
      overflow: hidden;
    }
    .command-palette-input-row {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding: 0.75rem 1rem;
      border-bottom: 1px solid var(--border);
    }
    .command-palette-icon {
      font-size: 0.7rem;
      font-family: var(--font-mono);
      color: var(--text-muted);
      background: var(--bg-deep);
      padding: 0.15rem 0.4rem;
      border-radius: 4px;
      border: 1px solid var(--border);
      flex-shrink: 0;
    }
    .command-palette-input {
      flex: 1;
      border: none;
      outline: none;
      background: transparent;
      font-family: var(--font-body);
      font-size: 0.9rem;
      color: var(--text-primary);
    }
    .command-palette-input::placeholder { color: var(--text-muted); }
    .command-palette-results {
      max-height: 300px;
      overflow-y: auto;
      padding: 0.25rem 0;
    }
    .command-palette-item {
      display: flex;
      align-items: center;
      justify-content: space-between;
      width: 100%;
      padding: 0.5rem 1rem;
      border: none;
      background: none;
      cursor: pointer;
      font-size: 0.85rem;
      color: var(--text-primary);
      text-align: left;
      transition: background 0.1s;
    }
    .command-palette-item:hover {
      background: var(--teal-dim);
    }
    .command-palette-item-label {
      flex: 1;
    }
    .command-palette-item-shortcut {
      font-family: var(--font-mono);
      font-size: 0.7rem;
      color: var(--text-muted);
      background: var(--bg-deep);
      padding: 0.1rem 0.35rem;
      border-radius: 3px;
      border: 1px solid var(--border);
    }
    .command-palette-empty {
      padding: 1rem;
      text-align: center;
      color: var(--text-muted);
      font-size: 0.85rem;
    }

    /* === Focus Mode === */
    .session-layout.focus-mode .session-header {
      display: none;
    }
    .session-layout.focus-mode .workspace-tab-bar {
      display: none;
    }
    .session-layout.focus-mode .main-panels {
      grid-template-columns: 1fr;
    }
    .session-layout.focus-mode .dt-chat-panel {
      width: 0;
      min-width: 0;
      opacity: 0;
      border-left: none;
      pointer-events: none;
    }
    .session-layout.focus-mode .agent-sidebar {
      display: none;
    }
    .session-layout.focus-mode {
      height: 100vh;
    }

    /* === Floating Chat Pill === */
    .chat-floating-pill {
      position: fixed;
      bottom: 1.5rem;
      right: 1.5rem;
      display: flex;
      align-items: center;
      gap: 0.4rem;
      padding: 0.5rem 1rem;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: 20px;
      box-shadow: var(--shadow-md);
      cursor: pointer;
      font-size: 0.825rem;
      font-weight: 500;
      color: var(--text-primary);
      z-index: 20;
      transition: all 0.2s ease;
    }
    .chat-floating-pill:hover {
      box-shadow: var(--shadow-lg);
      border-color: var(--teal);
    }
    .pill-unseen-badge {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: 18px;
      height: 18px;
      padding: 0 0.3rem;
      border-radius: 9px;
      background: var(--teal);
      color: white;
      font-size: 0.65rem;
      font-weight: 700;
      font-family: var(--font-mono);
      line-height: 1;
    }

    /* === Lens Dashboard === */
    .lens-dashboard {
      display: flex;
      flex-direction: column;
      height: 100%;
      min-height: 0;
      overflow-y: auto;
      padding: 1.5rem;
      gap: 1rem;
    }
    .lens-dashboard.hidden { display: none; }
    .lens-dashboard-header { margin-bottom: 0.5rem; }
    .lens-dashboard-title {
      font-size: 1.1rem;
      font-weight: 600;
      color: var(--text-primary);
    }
    .lens-dashboard-desc {
      font-size: 0.85rem;
      color: var(--text-secondary);
      margin-top: 0.25rem;
    }
    .lens-dashboard-empty {
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100%;
    }

    /* Summary cards */
    .lens-summary-cards {
      display: flex;
      gap: 0.75rem;
      flex-wrap: wrap;
    }
    .lens-summary-card {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 0.75rem 1rem;
      min-width: 80px;
      text-align: center;
    }
    .lens-summary-value {
      font-size: 1.4rem;
      font-weight: 700;
      font-family: var(--font-mono);
      color: var(--text-primary);
    }
    .lens-summary-label {
      font-size: 0.7rem;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.04em;
      margin-top: 0.15rem;
    }

    /* Charts container */
    .lens-dashboard-charts { flex: 1; min-height: 0; }
    .lens-chart-pair {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 1rem;
    }
    .lens-chart-placeholder {
      color: var(--text-muted);
      text-align: center;
      padding: 3rem 1rem;
    }

    /* Matrix */
    .lens-matrix { display: flex; flex-direction: column; align-items: center; gap: 0.5rem; }
    .lens-matrix-ylabel {
      font-size: 0.75rem;
      color: var(--text-secondary);
      writing-mode: vertical-lr;
      transform: rotate(180deg);
      align-self: center;
    }
    .lens-matrix-xlabel {
      font-size: 0.75rem;
      color: var(--text-secondary);
      text-align: center;
    }
    .lens-matrix-grid {
      display: grid;
      gap: 4px;
      width: 100%;
      max-width: 360px;
    }
    .lens-matrix-row-label, .lens-matrix-col-label {
      font-size: 0.7rem;
      color: var(--text-muted);
      display: flex;
      align-items: center;
      justify-content: center;
      text-transform: capitalize;
    }
    .lens-matrix-cell {
      border: 1px solid;
      border-radius: var(--radius-sm);
      padding: 0.75rem 0.5rem;
      text-align: center;
      min-height: 60px;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 0.25rem;
      transition: opacity 0.15s;
    }
    .lens-matrix-cell:hover { opacity: 0.85; }
    .lens-matrix-cell-label { font-size: 0.75rem; font-weight: 600; }
    .lens-matrix-cell-count {
      font-size: 1.1rem;
      font-weight: 700;
      font-family: var(--font-mono);
      color: var(--text-primary);
    }

    /* Scatter */
    .lens-scatter-svg { width: 100%; height: auto; }

    /* Bar chart */
    .lens-bar-svg { width: 100%; height: auto; }

    /* Detail panel */
    .lens-detail-panel {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 1rem;
      margin-top: 1rem;
    }
    .lens-detail-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .lens-detail-title {
      font-size: 1rem;
      font-weight: 600;
    }
    .lens-detail-close {
      background: none;
      border: none;
      font-size: 1.2rem;
      color: var(--text-muted);
      cursor: pointer;
    }
    .lens-detail-meta {
      display: flex;
      gap: 0.5rem;
      margin: 0.5rem 0;
    }
    .lens-detail-classification {
      background: var(--teal-dim);
      color: var(--teal);
      padding: 2px 8px;
      border-radius: 10px;
      font-size: 0.75rem;
      font-weight: 600;
    }
    .lens-detail-method {
      color: var(--text-muted);
      font-size: 0.75rem;
    }
    .lens-detail-axes { display: flex; flex-direction: column; gap: 1rem; margin-top: 0.75rem; }
    .lens-detail-axis-header {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      font-size: 0.85rem;
    }
    .lens-detail-axis-name { font-weight: 600; color: var(--text-primary); }
    .lens-detail-axis-composite { font-family: var(--font-mono); color: var(--teal); font-weight: 700; }
    .lens-detail-axis-band { color: var(--text-muted); font-size: 0.75rem; text-transform: capitalize; }
    .lens-detail-variables { display: flex; flex-direction: column; gap: 0.5rem; margin-top: 0.5rem; }
    .lens-detail-var { padding-left: 0.75rem; }
    .lens-detail-var-header { display: flex; justify-content: space-between; font-size: 0.8rem; }
    .lens-detail-var-name { color: var(--text-secondary); }
    .lens-detail-var-score { font-family: var(--font-mono); color: var(--text-primary); font-size: 0.75rem; }
    .lens-detail-var-rationale {
      font-size: 0.75rem;
      color: var(--text-muted);
      margin-top: 0.15rem;
      font-style: italic;
    }
    .lens-detail-var-bar {
      height: 4px;
      background: var(--bg-deep);
      border-radius: 2px;
      margin-top: 0.25rem;
      overflow: hidden;
    }
    .lens-detail-var-bar-fill {
      height: 100%;
      background: var(--teal);
      border-radius: 2px;
      transition: width 0.3s;
    }

    /* === Chat Overlay === */
    .chat-overlay-backdrop {
      position: fixed;
      inset: 0;
      background: rgba(28, 25, 23, 0.15);
      z-index: 60;
      backdrop-filter: blur(4px);
    }
    .chat-overlay-panel {
      position: fixed;
      right: 1.5rem;
      bottom: 1.5rem;
      width: 420px;
      height: 560px;
      max-height: calc(100vh - 3rem);
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      box-shadow: var(--shadow-lg);
      z-index: 61;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    .chat-overlay-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0.75rem 1rem;
      border-bottom: 1px solid var(--border);
      background: var(--bg-surface);
      flex-shrink: 0;
    }
    .chat-overlay-title {
      font-size: 0.9rem;
      font-weight: 600;
      color: var(--text-primary);
    }
    .chat-overlay-close {
      width: 28px;
      height: 28px;
      border-radius: 50%;
      border: none;
      background: transparent;
      color: var(--text-muted);
      font-size: 1.1rem;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: background 0.15s, color 0.15s;
    }
    .chat-overlay-close:hover {
      background: var(--bg-hover);
      color: var(--text-primary);
    }
    .chat-overlay-feed {
      flex: 1;
      overflow-y: auto;
      padding: 0.75rem 1rem;
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
    }
    .chat-overlay-msg {
      display: flex;
      gap: 0.5rem;
      align-items: flex-start;
    }
    .chat-overlay-avatar {
      width: 28px;
      height: 28px;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 0.7rem;
      font-weight: 700;
      flex-shrink: 0;
    }
    .chat-overlay-avatar.avatar-user {
      background: var(--bg-hover);
      color: var(--text-secondary);
    }
    .chat-overlay-avatar.avatar-assistant {
      background: var(--teal-dim);
      color: var(--teal);
    }
    .chat-overlay-msg-body {
      font-size: 0.85rem;
      line-height: 1.5;
      color: var(--text-primary);
      white-space: pre-wrap;
      word-break: break-word;
      min-width: 0;
    }
    .chat-overlay-input-area {
      padding: 0.75rem 1rem;
      border-top: 1px solid var(--border);
      flex-shrink: 0;
    }
    .chat-overlay-input-form {
      display: flex;
      align-items: flex-end;
      gap: 0.5rem;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 0.5rem 0.75rem;
      transition: border-color 0.2s ease, box-shadow 0.2s ease;
    }
    .chat-overlay-input-form:focus-within {
      border-color: var(--teal);
      box-shadow: 0 0 0 3px var(--teal-glow);
    }
    .chat-overlay-input-form textarea {
      flex: 1;
      border: none;
      outline: none;
      background: transparent;
      color: var(--text-primary);
      font-family: inherit;
      font-size: 0.85rem;
      line-height: 1.5;
      resize: none;
      max-height: 120px;
    }
    .chat-overlay-input-form textarea::placeholder {
      color: var(--text-muted);
    }
    .chat-overlay-msg-content {
      font-size: 0.85rem;
      line-height: 1.5;
      color: var(--text-primary);
      min-width: 0;
      flex: 1;
    }
    .chat-overlay-msg-content .markdown-body {
      font-size: 0.85rem;
    }
    .chat-overlay-thinking {
      font-size: 0.8rem;
      color: var(--text-muted);
    }
    .chat-overlay-thinking summary {
      cursor: pointer;
      font-style: italic;
    }
    .chat-overlay-thinking-text {
      white-space: pre-wrap;
      word-break: break-word;
      font-size: 0.75rem;
      max-height: 120px;
      overflow-y: auto;
      margin-top: 0.25rem;
      padding: 0.5rem;
      background: var(--bg-deep);
      border-radius: var(--radius);
    }
    .chat-overlay-tool {
      display: flex;
      align-items: center;
      gap: 0.35rem;
      font-size: 0.8rem;
      color: var(--text-secondary);
      padding: 0.25rem 0;
    }

    /* === Admin: LLM Admission dashboard === */
    .admin-section { margin-bottom: 1.5rem; }
    .admin-section-title {
      font-size: 0.95rem;
      font-weight: 600;
      color: var(--text-primary);
      margin-bottom: 1rem;
    }
    .admin-stat-grid {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 1.25rem;
    }
    .admin-stat-label {
      font-size: 0.7rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--text-muted);
      margin-bottom: 0.35rem;
    }
    .admin-stat-value {
      font-family: var(--font-mono);
      font-size: 1.75rem;
      font-weight: 600;
      color: var(--text-primary);
      letter-spacing: -0.02em;
      line-height: 1;
    }
    .admin-stat-value.warn { color: var(--amber); }
    .admin-stat-value.danger { color: var(--red); }

    .admin-util { margin-top: 1.5rem; }
    .admin-util-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      font-size: 0.75rem;
      color: var(--text-muted);
      margin-bottom: 0.35rem;
    }
    .admin-util-bar {
      height: 8px;
      width: 100%;
      background: var(--bg-deep);
      border-radius: 999px;
      overflow: hidden;
    }
    .admin-util-fill {
      height: 100%;
      border-radius: 999px;
      transition: width 0.4s ease, background 0.2s;
      background: var(--green);
    }
    .admin-util-fill.warn { background: var(--amber); }
    .admin-util-fill.danger { background: var(--red); }

    .admin-event-time {
      font-family: var(--font-mono);
      font-size: 0.75rem;
      color: var(--text-secondary);
      white-space: nowrap;
    }
    .admin-event-name {
      font-family: var(--font-mono);
      font-size: 0.75rem;
      font-weight: 600;
    }
    .admin-event-name.acquire { color: var(--green); }
    .admin-event-name.release { color: var(--text-secondary); }
    .admin-event-name.queued  { color: var(--amber); }
    .admin-event-name.timeout { color: var(--red); }
    .admin-event-measurements {
      font-family: var(--font-mono);
      font-size: 0.75rem;
      color: var(--text-primary);
    }
    .admin-event-meta {
      font-family: var(--font-mono);
      font-size: 0.75rem;
      color: var(--text-muted);
      max-width: 240px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .admin-footnote {
      margin-top: 1rem;
      font-size: 0.75rem;
      color: var(--text-muted);
    }

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
