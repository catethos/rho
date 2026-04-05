defmodule RhoWeb.InlineCSS do
  @moduledoc """
  Inline CSS for the Rho LiveView UI — Light theme.
  Clean, minimal aesthetic with white backgrounds and teal accents.
  """

  def css do
    ~S"""
    /* === Reset & Base === */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      /* Light backgrounds */
      --bg-abyss: #f5f5f5;
      --bg-deep: #f0f0f0;
      --bg-mid: #f5f5f5;
      --bg-shelf: #fafafa;
      --bg-surface: #ffffff;
      --bg-hover: #f0f0f0;

      /* Borders */
      --border: #e5e5e5;
      --border-active: #ccc;
      --border-violet: rgba(91, 138, 186, 0.2);

      /* Text */
      --text-primary: #1a1a1a;
      --text-secondary: #6b6b6b;
      --text-muted: #999999;
      --text-teal: #4a9e8e;
      --text-glow: #5BB5A2;

      /* Teal accent — matching the image */
      --teal: #5BB5A2;
      --teal-bright: #4da693;
      --teal-dim: rgba(91, 181, 162, 0.08);
      --teal-glow: rgba(91, 181, 162, 0.1);
      --teal-glow-strong: rgba(91, 181, 162, 0.15);

      /* Secondary — cool blue */
      --violet: #5b8aba;
      --violet-dim: rgba(91, 138, 186, 0.08);
      --violet-glow: rgba(91, 138, 186, 0.1);

      /* Semantic */
      --green: #5BB5A2;
      --green-dim: rgba(91, 181, 162, 0.1);
      --amber: #d4a855;
      --amber-dim: rgba(212, 168, 85, 0.1);
      --red: #e5534b;
      --red-dim: rgba(229, 83, 75, 0.08);
      --blue: #5b8aba;
      --yellow: #d4a855;

      /* Typography */
      --font-body: 'Outfit', -apple-system, BlinkMacSystemFont, sans-serif;
      --font-mono: 'Fragment Mono', 'JetBrains Mono', 'SF Mono', monospace;

      /* Layout */
      --nav-height: 44px;

      /* Shape */
      --radius: 8px;
      --radius-sm: 5px;
      --radius-lg: 12px;

      /* Shadows — subtle for light theme */
      --shadow-sm: 0 1px 2px rgba(0,0,0,0.04);
      --shadow-md: 0 2px 8px rgba(0,0,0,0.06);
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
      letter-spacing: 0.005em;
    }

    body.rho-body > * { position: relative; z-index: 1; }

    /* === Flash messages === */
    .flash-container { position: fixed; top: 1rem; right: 1rem; z-index: 100; }
    .flash {
      padding: 0.75rem 1.25rem;
      border-radius: var(--radius);
      font-size: 0.875rem;
      margin-bottom: 0.5rem;
      max-width: 400px;
      cursor: pointer;
      box-shadow: var(--shadow-md);
    }
    .flash-info { background: rgba(91, 138, 186, 0.1); color: var(--blue); border: 1px solid rgba(91, 138, 186, 0.3); }
    .flash-error { background: var(--red-dim); color: var(--red); border: 1px solid rgba(229, 83, 75, 0.3); }

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
      font-size: 1.1rem;
      font-weight: 700;
      color: var(--text-primary);
      letter-spacing: -0.01em;
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
      background: #8b5cf6;
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
      grid-template-columns: 1fr 220px;
      min-height: 0;
    }

    .session-layout.drawer-pinned .main-panels {
      grid-template-columns: 1fr 220px;
    }

    @media (min-width: 1440px) {
      .session-layout.drawer-pinned .main-panels {
        grid-template-columns: 1fr 220px 380px;
      }
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
    .tab-label { font-size: 0.825rem; }
    .tab-typing {
      font-size: 0.75rem;
      color: var(--teal);
      animation: pulse 1.2s ease-in-out infinite;
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
    .avatar-user { background: #8b5cf6; }
    .avatar-agent-msg { background: #f59e0b; }
    .message-sender-label {
      font-size: 0.7rem;
      color: #f59e0b;
      margin-bottom: 2px;
    }
    .message-from-agent .message-content {
      border-left: 2px solid #f59e0b;
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
      border-left: 2px solid #e2d8f3;
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
      background: rgba(239, 68, 68, 0.1);
      border: 1px solid rgba(239, 68, 68, 0.3);
      border-radius: var(--radius);
      color: var(--red, #ef4444);
      font-size: 0.85rem;
    }
    .error-icon {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 1.2rem;
      height: 1.2rem;
      border-radius: 50%;
      background: var(--red, #ef4444);
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
      padding: 1rem 2rem;
      border-top: 1px solid var(--border);
      background: var(--bg-surface);
      flex-shrink: 0;
      width: 100%;
    }
    .chat-input-form {
      display: flex;
      align-items: flex-end;
      gap: 0.5rem;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      padding: 0.5rem 0.75rem;
      transition: border-color 0.15s;
    }
    .chat-input-form:focus-within { border-color: var(--teal); }

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
      line-height: 1.5;
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
      padding: 0.35rem 0.85rem;
      border-radius: var(--radius);
      border: none;
      background: var(--teal);
      color: white;
      font-size: 0.8rem;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.15s;
    }
    .btn-send:hover { background: var(--teal-bright); }
    .btn-send:disabled { opacity: 0.4; cursor: default; }

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
      box-shadow: -4px 0 16px rgba(0,0,0,0.06);
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
      background: rgba(0,0,0,0.2);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 50;
      backdrop-filter: blur(4px);
    }
    .modal-dialog {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      padding: 1.5rem;
      min-width: 320px;
      max-width: 480px;
      box-shadow: 0 16px 48px rgba(0,0,0,0.1);
    }
    .modal-dialog h3 {
      font-size: 1.1rem;
      font-weight: 600;
      margin-bottom: 1rem;
    }
    .agent-role-list {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
      margin-bottom: 1rem;
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
    .markdown-body { line-height: 1.65; }
    .markdown-body p { margin-bottom: 0.5em; }
    .markdown-body p:last-child { margin-bottom: 0; }
    .markdown-body code {
      background: var(--bg-deep);
      padding: 0.15rem 0.35rem;
      border-radius: 4px;
      font-family: var(--font-mono);
      font-size: 0.85em;
      color: var(--text-primary);
    }
    .markdown-body pre {
      background: var(--bg-deep);
      border: 1px solid var(--border);
      padding: 0.75rem 1rem;
      border-radius: var(--radius);
      overflow-x: auto;
      margin: 0.5rem 0;
    }
    .markdown-body pre code {
      background: none;
      padding: 0;
      font-size: 0.8rem;
    }
    .markdown-body ul, .markdown-body ol {
      padding-left: 1.5em;
      margin: 0.4em 0;
    }
    .markdown-body li { margin-bottom: 0.2em; }
    .markdown-body a { color: var(--teal); text-decoration: none; }
    .markdown-body a:hover { text-decoration: underline; }
    .markdown-body h1, .markdown-body h2, .markdown-body h3 {
      margin: 0.75em 0 0.25em;
      font-weight: 600;
      color: var(--text-primary);
    }
    .markdown-body blockquote {
      border-left: 3px solid var(--border);
      padding-left: 0.75rem;
      color: var(--text-secondary);
      margin: 0.5em 0;
    }
    .markdown-body table {
      border-collapse: collapse;
      margin: 0.5rem 0;
      font-size: 0.85rem;
    }
    .markdown-body th, .markdown-body td {
      border: 1px solid var(--border);
      padding: 0.35rem 0.6rem;
    }
    .markdown-body th {
      background: var(--bg-deep);
      font-weight: 600;
    }

    /* === JSON highlighting === */
    .json-key { color: var(--blue); }
    .json-string { color: var(--green); }
    .json-number { color: var(--amber); }
    .json-bool { color: var(--teal); }
    .json-null { color: var(--text-muted); }

    /* === Images === */
    .tool-output-image { max-width: 100%; border-radius: var(--radius); margin: 0.5rem 0; }
    .message-images img { max-width: 100%; border-radius: var(--radius); margin: 0.5rem 0; }

    /* === Scrollbar === */
    ::-webkit-scrollbar { width: 6px; height: 6px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb { background: #ddd; border-radius: 3px; }
    ::-webkit-scrollbar-thumb:hover { background: #ccc; }

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

    /* === Observatory === */

    /* --- Shell layout --- */
    .obs-shell { display: flex; flex-direction: column; height: calc(100vh - var(--nav-height)); overflow: hidden; }
    .obs-topbar {
      display: flex; justify-content: space-between; align-items: center;
      padding: 10px 20px; border-bottom: 1px solid var(--border);
      background: var(--bg-surface);
    }
    .obs-topbar-left { display: flex; align-items: center; gap: 12px; }
    .obs-topbar-right { display: flex; align-items: center; gap: 10px; }
    .obs-logo { font-size: 15px; font-weight: 700; letter-spacing: -0.3px; }
    .obs-session-id {
      font-size: 12px; color: var(--text-muted);
      font-family: var(--font-mono); background: var(--bg-hover);
      padding: 2px 8px; border-radius: 4px;
    }
    .obs-stat-pill {
      font-size: 12px; color: var(--text-secondary);
      font-family: var(--font-mono);
    }
    .obs-status-pill {
      font-size: 11px; padding: 2px 10px; border-radius: 10px;
      font-weight: 600; text-transform: uppercase; letter-spacing: 0.3px;
    }
    .obs-status-not_started { background: var(--bg-hover); color: var(--text-muted); }
    .obs-status-running { background: rgba(91, 181, 162, 0.12); color: var(--teal); }
    .obs-status-replaying { background: rgba(91, 138, 186, 0.12); color: #5B8ABA; animation: pulse 1.5s infinite; }
    .obs-status-completed { background: rgba(39, 174, 96, 0.12); color: #27ae60; }

    /* Replay controls */
    .obs-replay-controls {
      display: flex; align-items: center; gap: 4px;
      padding: 2px 6px; border-radius: 6px;
      background: var(--bg-hover); border: 1px solid var(--border);
    }
    .obs-replay-btn {
      background: none; border: none; cursor: pointer;
      font-size: 13px; padding: 2px 6px; border-radius: 4px;
      color: var(--text-secondary);
    }
    .obs-replay-btn:hover { background: var(--bg-surface); color: var(--text-primary); }
    .obs-replay-speed {
      background: none; border: none; cursor: pointer;
      font-size: 10px; padding: 2px 6px; border-radius: 4px;
      color: var(--text-muted); font-weight: 600;
      text-transform: uppercase; letter-spacing: 0.3px;
      font-family: var(--font-mono);
    }
    .obs-replay-speed:hover { color: var(--text-secondary); background: var(--bg-surface); }
    .obs-replay-speed.active { color: var(--teal); background: var(--teal-dim); }
    .obs-replay-remaining {
      font-size: 10px; color: var(--text-muted);
      font-family: var(--font-mono); padding-left: 4px;
    }

    .obs-body { display: flex; flex: 1; overflow: hidden; }
    .obs-timeline-pane { flex: 1; overflow-y: auto; padding: 0; }
    .obs-sidebar {
      width: 280px; border-left: 1px solid var(--border);
      overflow-y: auto; padding: 16px;
      display: flex; flex-direction: column; gap: 20px;
    }
    .obs-sidebar-section {}
    .obs-sidebar-title {
      font-size: 11px; font-weight: 700; color: var(--text-muted);
      text-transform: uppercase; letter-spacing: 0.8px; margin-bottom: 10px;
    }
    .obs-muted { font-size: 13px; color: var(--text-muted); font-style: italic; }

    /* --- Buttons --- */
    .obs-btn {
      background: var(--teal); color: white; border: none;
      border-radius: 6px; cursor: pointer;
      font-family: var(--font-body); font-weight: 600;
    }
    .obs-btn:hover { opacity: 0.9; }
    .obs-btn-lg { padding: 14px 36px; font-size: 16px; border-radius: 8px; margin-top: 24px; }
    .obs-btn-sm { padding: 5px 14px; font-size: 12px; }

    /* --- Landing --- */
    .obs-landing {
      display: flex; flex-direction: column; align-items: center;
      justify-content: center; height: calc(100vh - var(--nav-height)); text-align: center; padding: 40px;
    }
    .obs-landing h1 { font-size: 2rem; font-weight: 700; margin-bottom: 12px; }
    .obs-landing p { color: var(--text-secondary); max-width: 500px; line-height: 1.7; }

    /* Session list on landing */
    .obs-session-list {
      margin-top: 36px; width: 100%; max-width: 480px; text-align: left;
    }
    .obs-session-list-title {
      font-size: 12px; font-weight: 700; color: var(--text-muted);
      text-transform: uppercase; letter-spacing: 0.8px; margin-bottom: 10px;
    }
    .obs-session-link {
      display: flex; justify-content: space-between; align-items: center;
      padding: 10px 14px; border: 1px solid var(--border); border-radius: 8px;
      margin-bottom: 6px; text-decoration: none; color: var(--text-primary);
      transition: border-color 0.15s, background 0.15s;
    }
    .obs-session-link:hover { border-color: var(--teal); background: var(--teal-dim); }
    .obs-session-link-id {
      font-family: var(--font-mono); font-size: 14px; font-weight: 600;
    }
    .obs-session-link-meta {
      font-size: 12px; color: var(--text-muted); font-family: var(--font-mono);
    }

    /* --- Agent pills (sidebar) --- */
    .obs-agent-pill {
      display: flex; align-items: center; gap: 8px;
      padding: 8px 10px; border-radius: 8px;
      border: 1px solid var(--border); margin-bottom: 6px;
      transition: border-color 0.2s, box-shadow 0.2s;
    }
    .obs-agent-pill.busy {
      border-color: var(--teal);
      box-shadow: 0 0 0 1px rgba(91, 181, 162, 0.15);
    }
    .obs-agent-pill.dead { opacity: 0.45; }
    .obs-agent-pill-info { flex: 1; min-width: 0; }
    .obs-agent-pill-name { font-size: 13px; font-weight: 600; display: block; }
    .obs-agent-pill-meta {
      font-size: 11px; color: var(--text-muted);
      font-family: var(--font-mono);
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .obs-status-dot {
      width: 8px; height: 8px; border-radius: 50%;
      background: var(--text-muted); flex-shrink: 0;
    }
    .obs-status-dot.busy { background: var(--teal); animation: pulse 1.5s infinite; }

    /* --- Score table (sidebar) --- */
    .obs-score-tbl { width: 100%; border-collapse: collapse; font-size: 12px; }
    .obs-score-tbl th {
      text-align: center; padding: 4px 3px; font-weight: 500;
      color: var(--text-muted); border-bottom: 1px solid var(--border);
    }
    .obs-score-tbl th:first-child { text-align: left; }
    .obs-score-tbl td { text-align: center; padding: 4px 3px; border-bottom: 1px solid var(--border); }
    .obs-score-name { text-align: left !important; font-weight: 500; }
    .obs-score-avg { font-weight: 600; }
    .sc-high { color: #27ae60; font-weight: 600; }
    .sc-mid { color: var(--text-primary); }
    .sc-low { color: #e74c3c; }
    .sc-pending { color: var(--text-muted); }

    /* --- Token summary (sidebar) --- */
    .obs-token-summary { font-size: 13px; }
    .obs-token-row { display: flex; justify-content: space-between; padding: 3px 0; }
    .obs-token-label { color: var(--text-muted); }
    .obs-token-value { font-family: var(--font-mono); font-weight: 500; }
    .obs-token-total { border-top: 1px solid var(--border); margin-top: 4px; padding-top: 6px; font-weight: 600; }

    /* ============================== */
    /* --- Discussion timeline ---    */
    /* ============================== */

    .disc-timeline { padding: 20px 24px 40px; max-width: 820px; margin: 0 auto; }
    .disc-empty { color: var(--text-muted); font-style: italic; padding: 60px 0; text-align: center; }
    .disc-entry-wrap { margin-bottom: 4px; animation: disc-slide-in 0.25s ease-out; }

    @keyframes disc-slide-in {
      from { opacity: 0; transform: translateY(8px); }
      to { opacity: 1; transform: translateY(0); }
    }

    /* Role color palette */
    --clr-default: var(--teal);
    --clr-coordinator: var(--teal);
    .disc-role-default { --role-clr: var(--teal); --role-bg: rgba(91, 181, 162, 0.08); }
    .disc-role-primary { --role-clr: var(--teal); --role-bg: rgba(91, 181, 162, 0.08); }
    .disc-role-technical-evaluator { --role-clr: #5B8ABA; --role-bg: rgba(91, 138, 186, 0.08); }
    .disc-role-culture-evaluator { --role-clr: #B55BA0; --role-bg: rgba(181, 91, 160, 0.08); }
    .disc-role-compensation-evaluator { --role-clr: #D4A855; --role-bg: rgba(212, 168, 85, 0.08); }
    .disc-role-coder { --role-clr: #7C6EE6; --role-bg: rgba(124, 110, 230, 0.08); }
    .disc-role-researcher { --role-clr: #4ABFBF; --role-bg: rgba(74, 191, 191, 0.08); }
    .disc-role-unknown { --role-clr: var(--text-muted); --role-bg: var(--bg-hover); }

    /* --- Avatar --- */
    .disc-avatar {
      display: inline-flex; align-items: center; justify-content: center;
      width: 28px; height: 28px; border-radius: 8px;
      font-size: 13px; font-weight: 700; flex-shrink: 0;
      color: white;
    }
    .disc-avatar-sm { width: 24px; height: 24px; font-size: 11px; border-radius: 6px; }
    .disc-avatar-dim { opacity: 0.5; }
    .disc-avatar-default, .disc-avatar-primary { background: var(--teal); }
    .disc-avatar-technical-evaluator { background: #5B8ABA; }
    .disc-avatar-culture-evaluator { background: #B55BA0; }
    .disc-avatar-compensation-evaluator { background: #D4A855; }
    .disc-avatar-coder { background: #7C6EE6; }
    .disc-avatar-researcher { background: #4ABFBF; }
    .disc-avatar-unknown { background: var(--text-muted); }

    /* --- Message bubble --- */
    .disc-message {
      background: var(--role-bg, var(--bg-hover));
      border-left: 3px solid var(--role-clr, var(--border));
      border-radius: 0 10px 10px 0;
      padding: 10px 14px; margin: 6px 0;
      animation: disc-msg-appear 0.4s ease-out;
    }
    @keyframes disc-msg-appear {
      from { border-left-width: 3px; box-shadow: -2px 0 12px 0 var(--role-clr, transparent); }
      to { border-left-width: 3px; box-shadow: none; }
    }
    .disc-message-header {
      display: flex; align-items: center; gap: 8px; margin-bottom: 6px;
    }
    .disc-author { font-size: 13px; font-weight: 700; color: var(--role-clr, var(--text-primary)); }
    .disc-target {
      font-size: 11px; color: var(--text-muted);
      font-family: var(--font-mono);
    }
    .disc-broadcast { color: var(--amber); font-weight: 600; }
    .disc-message-body {
      font-size: 14px; line-height: 1.65; color: var(--text-primary);
      word-break: break-word; white-space: pre-wrap;
    }
    .disc-message-body p { margin: 0 0 8px; }
    .disc-message-body p:last-child { margin-bottom: 0; }
    .disc-message-body ul, .disc-message-body ol { margin: 4px 0 8px 20px; }
    .disc-message-body code {
      font-family: var(--font-mono); font-size: 12px;
      background: rgba(0,0,0,0.04); padding: 1px 4px; border-radius: 3px;
    }
    .disc-message-body pre {
      background: rgba(0,0,0,0.03); padding: 10px 12px;
      border-radius: 6px; overflow-x: auto; margin: 6px 0;
    }
    .disc-message-body pre code { background: none; padding: 0; }
    .disc-message-body table { border-collapse: collapse; margin: 8px 0; font-size: 13px; }
    .disc-message-body th, .disc-message-body td {
      border: 1px solid var(--border); padding: 4px 8px; text-align: left;
    }
    .disc-message-body th { background: var(--bg-hover); font-weight: 600; }

    /* --- Thinking (muted, collapsed feel) --- */
    .disc-thinking {
      padding: 6px 14px; margin: 2px 0;
      border-left: 2px dashed var(--border);
      opacity: 0.55; transition: opacity 0.15s;
    }
    .disc-thinking:hover { opacity: 0.85; }
    .disc-thinking-header {
      display: flex; align-items: center; gap: 6px; margin-bottom: 2px;
    }
    .disc-author-dim { font-size: 12px; font-weight: 600; color: var(--text-muted); }
    .disc-thinking-label {
      font-size: 10px; color: var(--text-muted); font-style: italic;
      background: var(--bg-hover); padding: 1px 6px; border-radius: 3px;
    }
    .disc-thinking-body {
      font-size: 12px; line-height: 1.5; color: var(--text-muted);
      white-space: pre-wrap; word-break: break-word;
      font-family: var(--font-mono);
    }

    /* --- Tool annotation (inline, compact) --- */
    .disc-tool {
      display: flex; align-items: center; gap: 6px;
      padding: 4px 14px; margin: 2px 0;
      font-size: 12px; font-family: var(--font-mono);
      color: var(--text-muted);
    }
    .disc-tool-icon { font-size: 13px; }
    .disc-tool-agent { font-weight: 600; color: var(--role-clr, var(--text-secondary)); font-size: 11px; }
    .disc-tool-name { color: var(--teal); font-weight: 600; }
    .disc-tool-args {
      color: var(--text-muted); overflow: hidden;
      text-overflow: ellipsis; white-space: nowrap; max-width: 400px;
    }
    .disc-tool-result {
      padding: 2px 14px 2px 28px; margin: 0 0 2px;
      font-size: 11px; font-family: var(--font-mono);
      color: var(--text-muted); line-height: 1.4;
      white-space: pre-wrap; word-break: break-word;
    }
    .disc-tool-result-status { margin-right: 4px; }
    .disc-tool-result-text { opacity: 0.7; }
    .disc-tool-error { color: var(--red); }
    .disc-tool-error .disc-tool-result-text { opacity: 1; }

    /* --- Event marker (join/leave) --- */
    .disc-event {
      display: flex; align-items: center; gap: 8px;
      padding: 6px 14px; font-size: 12px; color: var(--text-muted);
    }
    .disc-event-dot {
      width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0;
      animation: disc-dot-pop 0.4s ease-out;
    }
    @keyframes disc-dot-pop {
      0% { transform: scale(0); }
      60% { transform: scale(1.5); }
      100% { transform: scale(1); }
    }
    .disc-event-text strong { color: var(--text-secondary); font-weight: 600; }

    /* --- Round / phase markers --- */
    .disc-marker {
      display: flex; align-items: center; gap: 12px;
      padding: 12px 0; margin: 8px 0;
    }
    .disc-marker-line { flex: 1; height: 1px; background: var(--border); }
    .disc-marker-text {
      font-size: 12px; font-weight: 700; color: var(--text-muted);
      text-transform: uppercase; letter-spacing: 0.5px; white-space: nowrap;
    }
    .disc-marker-complete .disc-marker-line { background: #27ae60; }
    .disc-marker-complete .disc-marker-text { color: #27ae60; }

    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.5; }
    }

    /* ============================== */
    /* --- Interaction Graph ---      */
    /* ============================== */

    .igraph-wrap {
      border: 1px solid var(--border); border-radius: 10px;
      background: var(--bg-surface); overflow: hidden;
      position: relative;
    }
    .igraph-svg { width: 100%; height: auto; display: block; }

    /* Edges */
    .igraph-edge {
      stroke: var(--text-muted); opacity: 0.35;
      stroke-linecap: round;
      transition: opacity 0.3s, stroke-width 0.3s;
    }
    .igraph-edge-default, .igraph-edge-primary { stroke: var(--teal); opacity: 0.45; }
    .igraph-edge-technical-evaluator { stroke: #5B8ABA; opacity: 0.45; }
    .igraph-edge-culture-evaluator { stroke: #B55BA0; opacity: 0.45; }
    .igraph-edge-compensation-evaluator { stroke: #D4A855; opacity: 0.45; }
    .igraph-edge-coder { stroke: #7C6EE6; opacity: 0.45; }
    .igraph-edge-researcher { stroke: #4ABFBF; opacity: 0.45; }

    /* Nodes */
    .igraph-node {
      fill: var(--text-muted);
      transition: filter 0.3s;
    }
    .igraph-node-default, .igraph-node-primary { fill: var(--teal); }
    .igraph-node-technical-evaluator { fill: #5B8ABA; }
    .igraph-node-culture-evaluator { fill: #B55BA0; }
    .igraph-node-compensation-evaluator { fill: #D4A855; }
    .igraph-node-coder { fill: #7C6EE6; }
    .igraph-node-researcher { fill: #4ABFBF; }
    .igraph-node-unknown { fill: var(--text-muted); }

    .igraph-label {
      fill: white; font-size: 11px; font-weight: 700;
      text-anchor: middle; dominant-baseline: central;
      font-family: var(--font-body); pointer-events: none;
    }
    .igraph-name {
      fill: var(--text-secondary); font-size: 8px;
      text-anchor: middle; dominant-baseline: hanging;
      font-family: var(--font-body); pointer-events: none;
    }

    /* Pulse ring for busy agents */
    .igraph-pulse-ring {
      fill: none; stroke-width: 2;
      animation: igraph-pulse 1.5s ease-out infinite;
    }
    .igraph-ring-default, .igraph-ring-primary { stroke: var(--teal); }
    .igraph-ring-technical-evaluator { stroke: #5B8ABA; }
    .igraph-ring-culture-evaluator { stroke: #B55BA0; }
    .igraph-ring-compensation-evaluator { stroke: #D4A855; }
    .igraph-ring-coder { stroke: #7C6EE6; }
    .igraph-ring-researcher { stroke: #4ABFBF; }

    @keyframes igraph-pulse {
      0% { r: 16; opacity: 0.6; stroke-width: 2; }
      100% { r: 28; opacity: 0; stroke-width: 0.5; }
    }

    /* Animated particles */
    .igraph-particle {
      fill: var(--teal);
    }
    .igraph-particle-default, .igraph-particle-primary { fill: var(--teal); }
    .igraph-particle-technical-evaluator { fill: #5B8ABA; }
    .igraph-particle-culture-evaluator { fill: #B55BA0; }
    .igraph-particle-compensation-evaluator { fill: #D4A855; }
    .igraph-particle-coder { fill: #7C6EE6; }
    .igraph-particle-researcher { fill: #4ABFBF; }

    /* Ambient looping particles for historical/idle view */
    .igraph-ambient { opacity: 0.6; }

    /* Burst particles for live messages */
    .igraph-burst { opacity: 0; }

    /* Node glow ring */
    .igraph-node-glow { stroke: none; }

    /* === Spreadsheet Layout === */
    .spreadsheet-layout {
      display: flex;
      height: calc(100vh - var(--nav-height));
      overflow: hidden;
      background: var(--bg-abyss);
    }

    .spreadsheet-panel {
      flex: 1;
      min-width: 0;
      min-height: 0;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }

    .spreadsheet-toolbar {
      display: flex;
      align-items: center;
      gap: 14px;
      padding: 0 20px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border);
      height: 52px;
      flex-shrink: 0;
    }

    .spreadsheet-title {
      font-size: 0.9375rem;
      font-weight: 600;
      color: var(--text-primary);
      letter-spacing: -0.01em;
    }

    .spreadsheet-row-count,
    .ss-row-count {
      font-size: 11px;
      color: var(--text-muted);
      font-family: 'Fragment Mono', monospace;
      padding: 3px 10px;
      background: var(--bg-deep);
      border-radius: 10px;
    }

    .spreadsheet-cost {
      font-size: 11px;
      color: var(--teal);
      font-family: 'Fragment Mono', monospace;
      margin-left: auto;
      padding: 3px 10px;
      background: var(--teal-dim);
      border-radius: 10px;
    }

    /* === Spreadsheet Table === */
    .ss-table-wrap {
      flex: 1;
      min-height: 0;
      overflow: auto;
      padding: 16px 20px 32px;
      scroll-behavior: smooth;
    }

    .ss-table {
      width: 100%;
      border-collapse: separate;
      border-spacing: 0;
      font-size: 12.5px;
      line-height: 1.5;
    }
    .ss-th {
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
    .ss-th:first-child { border-radius: 6px 0 0 0; }
    .ss-th:last-child { border-radius: 0 6px 0 0; }

    /* Column proportions — no category/cluster since shown in group headers */
    .ss-th-id, .ss-td-id { width: 44px; text-align: center; color: var(--text-muted); font-family: 'Fragment Mono', monospace; font-size: 11px; }
    .ss-th-skill, .ss-td-skill_name { width: 18%; }
    .ss-th-desc, .ss-td-skill_description { width: 26%; }
    .ss-th-lvl, .ss-td-level { width: 44px; text-align: center; font-family: 'Fragment Mono', monospace; }
    .ss-th-lvlname, .ss-td-level_name { width: 14%; }
    .ss-th-lvldesc, .ss-td-level_description { }

    .ss-row {
      transition: background 0.12s ease;
    }
    .ss-row:hover {
      background: var(--teal-dim);
    }
    .ss-row td:first-child { border-left: 3px solid transparent; }
    .ss-row:hover td:first-child { border-left-color: var(--teal); }

    .ss-td {
      padding: 10px 14px;
      color: var(--text-primary);
      vertical-align: top;
      border-bottom: 1px solid var(--border);
      cursor: default;
    }
    .ss-td-skill_name {
      font-weight: 500;
      color: var(--text-primary);
    }
    .ss-td-skill_description,
    .ss-td-level_description {
      color: var(--text-secondary);
      line-height: 1.55;
      font-size: 12px;
    }
    .ss-td-level {
      font-weight: 600;
      color: var(--teal);
    }
    .ss-td-level_name {
      font-weight: 500;
    }

    /* Level badge coloring */
    .ss-row:nth-child(odd) {
      background: var(--bg-surface);
    }
    .ss-row:nth-child(even) {
      background: var(--bg-shelf);
    }
    .ss-row:hover {
      background: var(--teal-dim);
    }

    /* Streaming animation */
    @keyframes ss-flash {
      0% { background: var(--teal-glow-strong); }
      100% { background: transparent; }
    }
    .ss-row-new {
      animation: ss-flash 1s ease-out;
    }

    /* Inline editing */
    .ss-cell-input {
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
    .ss-cell-input:focus {
      border-color: var(--teal-bright);
      box-shadow: 0 0 0 3px var(--teal-glow-strong);
    }
    textarea.ss-cell-input {
      min-height: 60px;
      resize: vertical;
      line-height: 1.5;
    }

    /* Empty state */
    .ss-empty {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 12px;
      padding: 80px 40px;
      color: var(--text-muted);
      font-size: 0.875rem;
    }
    .ss-empty::before {
      content: '';
      display: block;
      width: 48px;
      height: 48px;
      border-radius: 12px;
      background: var(--teal-dim);
      border: 2px dashed var(--border);
    }

    /* === Collapsible Groups === */
    .ss-cat-group {
      margin-bottom: 12px;
      border-radius: 8px;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      overflow: hidden;
    }
    .ss-cat-group:last-child { margin-bottom: 0; }

    .ss-group { border: none; }

    .ss-group-header {
      display: flex;
      align-items: center;
      gap: 10px;
      cursor: pointer;
      user-select: none;
      list-style: none;
      transition: background 0.12s ease;
    }
    .ss-group-header::-webkit-details-marker { display: none; }
    .ss-group-header::marker { content: ''; }

    .ss-cat-header {
      padding: 12px 16px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border);
      font-weight: 600;
      font-size: 0.8125rem;
      color: var(--text-primary);
    }
    .ss-cat-group.ss-collapsed > .ss-cat-header {
      border-bottom-color: transparent;
    }

    .ss-cluster-header {
      padding: 9px 16px 9px 20px;
      background: var(--bg-shelf);
      border-bottom: 1px solid var(--border);
      font-weight: 500;
      font-size: 0.8125rem;
      color: var(--text-secondary);
    }
    .ss-cluster-group.ss-collapsed:last-child > .ss-cluster-header {
      border-bottom-color: transparent;
    }

    .ss-group-header:hover {
      background: var(--bg-hover);
    }

    .ss-chevron {
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
    .ss-chevron::after {
      content: '';
      display: block;
      width: 0;
      height: 0;
      border-left: 4px solid var(--text-muted);
      border-top: 3px solid transparent;
      border-bottom: 3px solid transparent;
      transition: transform 0.2s ease;
    }
    .ss-group:not(.ss-collapsed) > .ss-group-header .ss-chevron::after {
      transform: rotate(90deg);
    }
    .ss-group-header:hover .ss-chevron {
      background: var(--border);
    }

    .ss-group-name {
      flex: 1;
    }
    .ss-cat-header .ss-group-name {
      letter-spacing: 0.01em;
    }

    .ss-group-count {
      font-size: 11px;
      color: var(--text-muted);
      font-weight: 400;
      font-family: 'Fragment Mono', monospace;
      padding: 2px 8px;
      background: var(--bg-deep);
      border-radius: 10px;
    }

    .ss-group-content {
      transition: none;
    }
    .ss-hidden {
      display: none;
    }

    .ss-cluster-group .ss-table {
      margin: 0;
    }
    .ss-cluster-group:last-child .ss-table tr:last-child td {
      border-bottom: none;
    }

    /* Spreadsheet chat panel */
    .spreadsheet-chat-panel {
      width: 380px;
      min-width: 320px;
      max-width: 480px;
      border-left: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      background: var(--bg-surface);
    }

    .spreadsheet-chat-header {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 10px 16px;
      border-bottom: 1px solid var(--border);
      height: 48px;
      flex-shrink: 0;
    }

    .spreadsheet-chat-title {
      font-size: 0.875rem;
      font-weight: 600;
      color: var(--text-primary);
    }

    .spreadsheet-chat-panel .chat-feed {
      flex: 1;
      overflow-y: auto;
    }

    .spreadsheet-chat-panel .chat-input-area {
      border-top: 1px solid var(--border);
    }

    /* Streaming indicator on toolbar */
    .spreadsheet-streaming {
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

    .spreadsheet-streaming::before {
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
      box-shadow: var(--shadow-md);
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
      padding: 0.6rem;
      margin-top: 0.5rem;
      font-family: var(--font-body);
      font-size: 0.875rem;
      font-weight: 600;
      color: #fff;
      background: var(--teal);
      border: none;
      border-radius: var(--radius);
      cursor: pointer;
      transition: background 0.15s;
    }

    .auth-button:hover {
      background: var(--teal-bright);
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
      display: flex;
      align-items: center;
      justify-content: space-between;
      height: var(--nav-height);
      padding: 0 1.25rem;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border);
      flex-shrink: 0;
      z-index: 50;
    }
    .global-nav-left { display: flex; align-items: center; gap: 1.5rem; }
    .global-nav-logo {
      font-family: var(--font-mono);
      font-size: 1rem;
      font-weight: 700;
      color: var(--teal);
      text-decoration: none;
      letter-spacing: -0.02em;
    }
    .global-nav-links { display: flex; gap: 0.25rem; }
    .global-nav-link {
      padding: 0.3rem 0.65rem;
      font-size: 0.8rem;
      font-weight: 500;
      color: var(--text-secondary);
      text-decoration: none;
      border-radius: var(--radius-sm);
      transition: all 0.15s;
    }
    .global-nav-link:hover { color: var(--text-primary); background: var(--bg-hover); }
    .global-nav-link[aria-current="page"] {
      color: var(--teal);
      background: var(--teal-dim);
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

    @media (max-width: 640px) {
      .global-nav-links { display: none; }
    }

    /* === Auth logo === */
    .auth-logo {
      font-family: var(--font-mono);
      font-size: 1.5rem;
      font-weight: 700;
      color: var(--teal);
      text-align: center;
      margin-bottom: 1.5rem;
      letter-spacing: -0.03em;
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
      color: #fff; background: var(--teal);
      border: none; border-radius: var(--radius);
      cursor: pointer; transition: background 0.15s;
      text-decoration: none;
    }
    .btn-primary:hover { background: var(--teal-bright); }

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
    .fw-section { margin-bottom: 2rem; }
    .fw-section-title { font-size: 1.1rem; font-weight: 600; color: var(--text-primary); margin-bottom: 1rem; padding-bottom: 0.5rem; border-bottom: 1px solid var(--border); }
    .fw-cluster { margin-bottom: 1.5rem; }
    .fw-cluster-title { font-size: 0.9rem; font-weight: 500; color: var(--text-secondary); margin-bottom: 0.5rem; }
    """
  end
end
