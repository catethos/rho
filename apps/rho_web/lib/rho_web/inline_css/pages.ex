defmodule RhoWeb.InlineCSS.Pages do
  @moduledoc false

  def css do
    ~S"""
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

    """
  end
end
