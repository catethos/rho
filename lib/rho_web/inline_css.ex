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
      overflow: hidden;
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
      height: 100vh;
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

    /* Layout */
    .obs-layout { display: flex; flex-direction: column; height: 100vh; overflow: hidden; }
    .obs-header { display: flex; justify-content: space-between; align-items: center;
      padding: 12px 20px; border-bottom: 1px solid var(--border); background: var(--bg-surface); }
    .obs-title { font-size: 1.1rem; font-weight: 600; }
    .obs-header-stats { display: flex; gap: 16px; align-items: center; font-size: 13px; color: var(--text-secondary); }
    .obs-main { display: flex; flex: 1; overflow: hidden; }
    .obs-left { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
    .obs-right { width: 380px; border-left: 1px solid var(--border); overflow-y: auto; padding: 16px; }

    /* Section titles */
    .obs-section-title { font-size: 13px; font-weight: 600; color: var(--text-primary);
      margin-bottom: 12px; text-transform: uppercase; letter-spacing: 0.5px; }

    /* Agent cards */
    .obs-agents-grid { display: flex; flex-wrap: wrap; gap: 12px; padding: 16px; }
    .obs-agent-card { background: var(--bg-surface); border: 1px solid var(--border);
      border-radius: 8px; padding: 12px; min-width: 180px; flex: 1; cursor: pointer;
      transition: border-color 0.2s, box-shadow 0.2s; }
    .obs-agent-card:hover { border-color: var(--teal); }
    .obs-agent-card.busy { border-color: var(--teal); box-shadow: 0 0 8px rgba(91, 181, 162, 0.2); }
    .obs-agent-card.dead { border-color: #e74c3c; opacity: 0.6; }
    .obs-agent-header { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
    .obs-agent-role { font-weight: 600; font-size: 14px; }
    .obs-status-dot { width: 8px; height: 8px; border-radius: 50%; background: #ccc; flex-shrink: 0; }
    .obs-status-dot.busy { background: var(--teal); animation: pulse 1.5s infinite; }
    .obs-status-dot.idle { background: #aaa; }
    .obs-status-dot.dead { background: #e74c3c; }
    .obs-agent-stats { display: flex; gap: 12px; }
    .obs-stat { display: flex; flex-direction: column; align-items: center; }
    .obs-stat-label { font-size: 10px; color: var(--text-muted); text-transform: uppercase; }
    .obs-stat-value { font-size: 14px; font-weight: 500; font-family: 'Fragment Mono', monospace; }
    .obs-stat-value.hot { color: #e67e22; font-weight: 700; }
    .obs-agent-tool { font-size: 11px; color: var(--teal); margin-top: 6px;
      font-family: 'Fragment Mono', monospace; }
    .obs-tool-indicator { display: inline-block; width: 6px; height: 6px; border-radius: 50%;
      background: var(--teal); margin-right: 4px; animation: pulse 1s infinite; }
    .obs-agent-step { font-size: 11px; color: var(--text-muted); margin-top: 2px; }

    /* Unified timeline */
    .obs-timeline { flex: 1; overflow-y: auto; padding: 12px 16px; }
    .obs-timeline-entry { margin-bottom: 8px; }
    .obs-timeline-row { display: flex; gap: 8px; align-items: flex-start; font-size: 12px; color: var(--text-primary); }
    .obs-timeline-tag { padding: 1px 7px; border-radius: 4px; font-size: 10px; white-space: nowrap; color: #fff; font-weight: 500; flex-shrink: 0; margin-top: 1px; }
    .obs-timeline-tag-technical_evaluator { background: #5B8ABA; }
    .obs-timeline-tag-culture_evaluator { background: #B55BA0; }
    .obs-timeline-tag-compensation_evaluator { background: #D4A855; }
    .obs-timeline-tag-chairman { background: #5BB5A2; }

    /* Chairman summary block */
    .obs-timeline-summary {
      background: rgba(91, 181, 162, 0.06);
      border-left: 3px solid #5BB5A2;
      border-radius: 8px;
      padding: 12px 14px;
      margin: 12px 0;
      font-size: 13px;
    }
    .obs-timeline-summary-body { line-height: 1.6; margin-top: 8px; }
    .obs-timeline-rationale { color: var(--text-secondary); font-size: 11px; }
    .obs-timeline-round-divider { display: flex; align-items: center; gap: 10px; margin: 14px 0; font-size: 10px; color: var(--text-muted); font-weight: 500; text-transform: uppercase; }
    .obs-timeline-round-line { flex: 1; height: 1px; background: var(--border); }
    .obs-timeline-empty { color: var(--text-muted); font-style: italic; padding: 12px 0; }

    /* Debate messages in timeline */
    .obs-timeline-debate { display: flex; gap: 8px; align-items: flex-start; font-size: 12px; padding: 8px 10px; border-radius: 8px; }
    .obs-timeline-debate-technical_evaluator { background: rgba(91, 138, 186, 0.06); border-left: 3px solid #5B8ABA; }
    .obs-timeline-debate-culture_evaluator { background: rgba(181, 91, 160, 0.06); border-left: 3px solid #B55BA0; }
    .obs-timeline-debate-compensation_evaluator { background: rgba(212, 168, 85, 0.06); border-left: 3px solid #D4A855; }
    .obs-timeline-debate-to { font-size: 10px; color: var(--text-muted); margin-bottom: 3px; }
    .obs-timeline-debate-text { color: var(--text-primary); font-style: italic; line-height: 1.5; }

    /* Score deltas */
    .obs-delta-up { color: #27ae60; font-size: 10px; font-weight: 600; margin-left: 2px; }
    .obs-delta-down { color: #e74c3c; font-size: 10px; font-weight: 600; margin-left: 2px; }

    /* Agent drawer */
    .obs-drawer { position: absolute; right: 0; top: 0; bottom: 0; width: 380px; z-index: 30;
      background: var(--bg-surface); border-left: 1px solid var(--border);
      transform: translateX(100%); transition: transform 200ms ease-out;
      display: flex; flex-direction: column; overflow: hidden; }
    .obs-drawer.open { transform: translateX(0); box-shadow: -4px 0 12px rgba(0,0,0,0.06); }
    .obs-main { position: relative; }
    .obs-drawer-header { display: flex; justify-content: space-between; align-items: center;
      padding: 10px 14px; border-bottom: 1px solid var(--border); flex-shrink: 0; }
    .obs-drawer-name { display: flex; align-items: center; gap: 8px; }
    .obs-drawer-step { font-size: 11px; color: var(--text-muted); }
    .obs-drawer-close { cursor: pointer; color: var(--text-muted); font-size: 18px; padding: 4px; }
    .obs-drawer-close:hover { color: var(--text-primary); }
    .obs-drawer-body { flex: 1; overflow-y: auto; padding: 12px 14px; }
    .obs-drawer-text { background: var(--bg-shelf); border-radius: 8px; padding: 10px 12px;
      margin-bottom: 10px; font-size: 12px; line-height: 1.6; color: var(--text-primary);
      white-space: pre-wrap; word-break: break-word; max-height: 300px; overflow-y: auto; }
    .obs-drawer-tool-pill { display: inline-block; background: rgba(91,181,162,0.1); color: var(--teal);
      padding: 2px 8px; border-radius: 12px; font-size: 10px; margin: 4px 2px; }
    .obs-drawer-tool-result { font-size: 10px; color: var(--text-secondary); padding: 2px 0; }
    .obs-drawer-waiting { color: var(--text-muted); font-style: italic; padding: 12px 0; }

    /* Scoreboard */
    .obs-scoreboard { margin-bottom: 24px; }
    .obs-score-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .obs-score-table th { text-align: center; padding: 6px 4px; color: var(--text-muted);
      font-weight: 500; border-bottom: 1px solid var(--border); }
    .obs-score-table th:first-child { text-align: left; }
    .obs-score-table td { text-align: center; padding: 6px 4px;
      border-bottom: 1px solid var(--border); }
    .obs-candidate-name { text-align: left !important; font-weight: 500; }
    .obs-score-high { color: #27ae60; font-weight: 600; }
    .obs-score-mid { color: var(--text-primary); }
    .obs-score-low { color: #e74c3c; }
    .obs-score-pending { color: var(--text-muted); }
    .obs-score-avg { font-weight: 600; }

    /* Insights bar */
    .obs-insights { display: flex; gap: 12px; padding: 8px 20px;
      background: rgba(91, 181, 162, 0.06); border-bottom: 1px solid var(--border); }
    .obs-insight { font-size: 12px; color: var(--text-secondary); display: flex; align-items: center; gap: 4px; }
    .obs-insight-highlight { color: var(--teal); font-weight: 500; }
    .obs-insight-icon { display: inline-flex; align-items: center; justify-content: center;
      width: 16px; height: 16px; border-radius: 50%; font-size: 10px; font-weight: 700; flex-shrink: 0; }
    .obs-insight-highlight .obs-insight-icon { background: var(--teal); color: white; }
    .obs-insight-info .obs-insight-icon { background: var(--border); color: var(--text-muted); }

    /* Convergence */
    .obs-convergence { margin-top: 16px; }
    .obs-convergence-svg { width: 100%; height: auto; }
    .obs-convergence-current { font-size: 12px; color: var(--text-secondary); margin-top: 4px; }

    /* Per-role colors for signal flow */
    .obs-role-technical_evaluator { color: #5B8ABA; }
    .obs-role-culture_evaluator { color: #B55BA0; }
    .obs-role-compensation_evaluator { color: #D4A855; }

    /* Candidate tooltip on scoreboard */
    .obs-cand-name-hover { border-bottom: 1px dashed var(--border); cursor: pointer; position: relative; }
    .obs-cand-name-hover:hover { color: var(--teal); border-bottom-color: var(--teal); }
    .obs-cand-tooltip { display: none; position: absolute; left: 0; top: 100%; margin-top: 4px;
      width: 260px; background: var(--bg-surface); border: 1px solid var(--border);
      border-radius: 10px; padding: 14px; box-shadow: 0 8px 24px rgba(0,0,0,0.12); z-index: 50;
      text-align: left; font-weight: normal; }
    .obs-cand-name-hover:hover .obs-cand-tooltip { display: block; }
    .obs-cand-tooltip-name { font-weight: 700; font-size: 14px; color: var(--text-primary); margin-bottom: 2px; }
    .obs-cand-tooltip-meta { font-size: 11px; color: var(--text-muted); margin-bottom: 8px; }
    .obs-cand-tooltip-row { display: flex; justify-content: space-between; font-size: 11px;
      padding: 3px 0; border-bottom: 1px solid var(--bg-shelf); color: var(--text-primary); }
    .obs-cand-tooltip-row:last-of-type { border-bottom: none; }
    .obs-cand-tooltip-label { color: var(--text-muted); font-size: 10px; }
    .obs-cand-tooltip-strength { font-size: 11px; color: var(--text-secondary); margin-top: 8px; line-height: 1.5; }

    /* Landing page */
    .obs-landing { display: flex; flex-direction: column; align-items: center;
      padding: 48px 32px; min-height: 100vh; text-align: center; }
    .obs-landing-header { text-align: center; margin-bottom: 36px; max-width: 560px; }
    .obs-landing-header h1 { font-size: 1.8rem; font-weight: 700; color: var(--text-primary); margin-bottom: 8px; }
    .obs-landing-header p { color: var(--text-secondary); line-height: 1.6; font-size: 15px; }
    .obs-landing-section { margin-bottom: 32px; width: 100%; max-width: 720px; }
    .obs-landing-section-title { font-size: 11px; text-transform: uppercase; letter-spacing: 1px;
      color: var(--text-muted); margin-bottom: 10px; font-weight: 600; text-align: left; }
    .obs-start-meta { font-size: 12px; color: var(--text-muted); margin-top: 8px; }

    /* Evaluator cards */
    .obs-eval-cards { display: flex; gap: 12px; }
    .obs-eval-card { flex: 1; border-radius: 10px; padding: 14px; background: var(--bg-shelf);
      border: 1px solid var(--border); text-align: left; }
    .obs-eval-card-header { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
    .obs-eval-dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }
    .obs-eval-card-name { font-weight: 600; font-size: 14px; }
    .obs-eval-card-desc { font-size: 12px; color: var(--text-secondary); line-height: 1.5; margin-bottom: 6px; }
    .obs-eval-tag { display: inline-block; font-size: 10px; padding: 2px 8px; border-radius: 10px; font-weight: 500; }

    /* Candidate cards */
    .obs-cand-cards { display: flex; gap: 10px; flex-wrap: wrap; }
    .obs-cand-card { flex: 1; min-width: 130px; border-radius: 8px; padding: 10px 12px;
      background: var(--bg-shelf); border: 1px solid var(--border); text-align: left; }
    .obs-cand-card .obs-cand-name { font-weight: 600; font-size: 13px; color: var(--text-primary); margin-bottom: 2px; }
    .obs-cand-meta { font-size: 10px; color: var(--text-muted); margin-bottom: 6px; }
    .obs-cand-strength { font-size: 11px; color: var(--text-primary); line-height: 1.4; margin-bottom: 4px; }
    .obs-cand-tension { display: inline-block; font-size: 9px; padding: 2px 6px; border-radius: 8px;
      font-weight: 500; background: rgba(229,83,75,0.08); color: #e74c3c; }

    /* How it works */
    .obs-how { display: flex; gap: 16px; align-items: flex-start; justify-content: center; }
    .obs-how-step { text-align: center; flex: 1; max-width: 160px; }
    .obs-how-num { width: 28px; height: 28px; border-radius: 50%; background: var(--teal); color: #fff;
      display: flex; align-items: center; justify-content: center; font-size: 13px;
      font-weight: 600; margin: 0 auto 6px; }
    .obs-how-title { font-size: 12px; font-weight: 600; color: var(--text-primary); margin-bottom: 2px; }
    .obs-how-desc { font-size: 11px; color: var(--text-secondary); }
    .obs-how-arrow { color: var(--text-muted); font-size: 18px; padding-top: 4px; }
    .obs-start-btn-large { background: var(--teal); color: white; border: none;
      padding: 14px 32px; border-radius: 8px; font-size: 16px; cursor: pointer;
      font-family: 'Outfit', sans-serif; font-weight: 500; margin-top: 24px; }
    .obs-start-btn-large:hover { opacity: 0.9; }

    /* Start button (in-page) */
    .obs-start-btn { background: var(--teal); color: white; border: none;
      padding: 6px 16px; border-radius: 6px; font-size: 13px; cursor: pointer;
      font-family: 'Outfit', sans-serif; font-weight: 500; }
    .obs-start-btn:hover { opacity: 0.9; }

    /* Status badge */
    .obs-status-badge { font-size: 12px; padding: 2px 8px; border-radius: 4px;
      font-weight: 500; text-transform: uppercase; }
    .obs-status-not_started { background: var(--bg-hover); color: var(--text-muted); }
    .obs-status-running { background: rgba(91, 181, 162, 0.1); color: var(--teal); }
    .obs-status-completed { background: rgba(39, 174, 96, 0.1); color: #27ae60; }

    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.5; }
    }
    """
  end
end
