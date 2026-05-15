defmodule RhoWeb.InlineCSS.Chat do
  @moduledoc false

  def css do
    ~S"""
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

    .chat-attach-strip {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      padding: 4px 8px 0 8px;
    }
    .chat-attach-chip {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 8px;
      background: var(--bg-surface);
      border: 1px solid #e0e0e0;
      border-radius: 14px;
      font-size: 12px;
    }
    .chat-attach-chip.is-error {
      background: #fde0e0;
      border-color: #c92a2a;
    }
    .chat-attach-chip.is-parsing {
      background: #dceefb;
      border-color: #1971c2;
      animation: chat-attach-pulse 1.4s ease-in-out infinite;
    }
    @keyframes chat-attach-pulse {
      0%, 100% { opacity: 0.85; }
      50% { opacity: 1; }
    }
    .chat-attach-icon { font-size: 14px; }
    .chat-attach-name { max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .chat-attach-progress { color: var(--text-muted); font-variant-numeric: tabular-nums; }
    .chat-attach-error { color: #c92a2a; }
    .chat-attach-remove {
      background: transparent;
      border: 0;
      cursor: pointer;
      font-size: 14px;
      padding: 0 2px;
      color: var(--text-muted);
    }
    .chat-attach-remove:hover { color: var(--text); }
    .chat-attach-button {
      cursor: pointer;
      padding: 0 8px;
      display: inline-flex;
      align-items: center;
      font-size: 18px;
    }

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
    .new-chat-dialog {
      width: min(560px, calc(100vw - 2rem));
      max-width: 560px;
    }
    .new-chat-role-form {
      display: grid;
      grid-template-columns: 1fr;
      gap: 0.45rem;
      margin-bottom: 1rem;
    }
    .new-chat-role-btn {
      display: grid;
      grid-template-columns: 2rem minmax(0, 1fr);
      align-items: center;
      gap: 0.75rem;
      min-height: 3.6rem;
      padding: 0.65rem 0.75rem;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      background: var(--bg-surface);
      color: var(--text-primary);
      text-align: left;
      cursor: pointer;
      transition: border-color 0.15s, background 0.15s, box-shadow 0.15s;
      font: inherit;
    }
    .new-chat-role-btn:hover,
    .new-chat-role-btn:focus-visible {
      border-color: var(--teal);
      background: var(--teal-dim);
      box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--teal) 35%, transparent);
      outline: none;
    }
    .new-chat-role-mark {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 2rem;
      height: 2rem;
      border-radius: 6px;
      background: var(--bg-hover);
      color: var(--text-secondary);
      font-size: 0.78rem;
      font-weight: 700;
    }
    .new-chat-role-copy {
      display: flex;
      min-width: 0;
      flex-direction: column;
      gap: 0.15rem;
    }
    .new-chat-role-name {
      font-size: 0.86rem;
      font-weight: 650;
      line-height: 1.15;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .new-chat-role-desc {
      color: var(--text-muted);
      font-size: 0.72rem;
      line-height: 1.25;
      overflow: hidden;
      display: -webkit-box;
      -webkit-line-clamp: 2;
      -webkit-box-orient: vertical;
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

    """
  end
end
