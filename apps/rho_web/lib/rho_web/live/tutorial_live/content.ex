defmodule RhoWeb.TutorialLive.Content do
  @moduledoc false

  def sections do
    [
      {"welcome", "Welcome"},
      {"big-picture", "The big picture"},
      {"first-steps", "First steps"},
      {"pages", "What's on each page"},
      {"agents", "Meet the agents"},
      {"concepts", "Core concepts"},
      {"journeys", "Four user journeys"},
      {"frameworks", "Create a skill framework"},
      {"library-ops", "Library operations"},
      {"extending", "Extending Rho"},
      {"next", "You're ready"}
    ]
  end

  def style_tag do
    {:safe, ["<style>", css(), "</style>"]}
  end

  def example_agent_config do
    ~S'''
    my_helper: [
      model: "openrouter:anthropic/claude-haiku-4.5",
      description: "Triages support tickets and drafts a first reply",
      skills: ["customer support", "writing"],
      system_prompt: """
      You are a support triage assistant. Read the ticket, classify it,
      and propose a one-paragraph reply. Be brief and kind.
      """,
      plugins: [:journal, :web_fetch],
      turn_strategy: :direct,
      max_steps: 8
    ]
    '''
  end

  def css do
    """
    .tut-shell {
      min-height: 100vh;
      background: var(--bg-abyss);
      color: var(--text-primary);
      font-family: var(--font-body);
    }

    .tut-topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 1.1rem 2rem;
      border-bottom: 1px solid var(--border);
      background: var(--bg-surface);
    }
    .tut-logo {
      font-family: var(--font-mono);
      font-weight: 600;
      font-size: 1.1rem;
      color: var(--teal);
      text-decoration: none;
      letter-spacing: -0.02em;
    }
    .tut-topnav { display: flex; gap: 0.5rem; align-items: center; }
    .tut-topnav-link {
      padding: 0.5rem 0.9rem;
      font-size: 0.85rem;
      color: var(--text-secondary);
      text-decoration: none;
      border-radius: var(--radius-sm);
      transition: background 0.15s, color 0.15s;
    }
    .tut-topnav-link:hover { color: var(--text-primary); background: var(--bg-hover); }
    .tut-topnav-cta {
      background: var(--teal);
      color: #fff;
      border: 1px solid var(--teal);
    }
    .tut-topnav-cta:hover { background: var(--teal-bright); color: #fff; }

    .tut-layout {
      display: grid;
      grid-template-columns: 260px minmax(0, 1fr);
      gap: 2.5rem;
      max-width: 1200px;
      margin: 0 auto;
      padding: 2.5rem 2rem 6rem;
    }

    .tut-toc {
      position: sticky;
      top: 1.25rem;
      align-self: start;
      max-height: calc(100vh - 2.5rem);
      overflow-y: auto;
      padding-right: 0.5rem;
    }
    .tut-toc-title {
      text-transform: uppercase;
      font-size: 0.68rem;
      letter-spacing: 0.12em;
      color: var(--text-muted);
      margin-bottom: 0.75rem;
    }
    .tut-toc ol { list-style: none; padding: 0; margin: 0; }
    .tut-toc li { margin: 0; }
    .tut-toc-link {
      display: block;
      padding: 0.4rem 0.6rem;
      font-size: 0.85rem;
      color: var(--text-secondary);
      text-decoration: none;
      border-radius: var(--radius-sm);
      border-left: 2px solid transparent;
      transition: background 0.15s, color 0.15s, border-color 0.15s;
    }
    .tut-toc-link:hover { color: var(--text-primary); background: var(--bg-hover); }
    .tut-toc-link-active {
      color: var(--text-primary);
      background: var(--teal-glow);
      border-left-color: var(--teal);
      font-weight: 500;
    }
    .tut-toc-foot {
      margin-top: 1.5rem;
      padding-top: 1.25rem;
      border-top: 1px solid var(--border);
      font-size: 0.78rem;
      line-height: 1.55;
      color: var(--text-muted);
    }

    .tut-content { min-width: 0; }
    .tut-section {
      padding: 2rem 0 2.5rem;
      border-bottom: 1px solid var(--border);
    }
    .tut-section:last-child { border-bottom: none; }
    .tut-section h2 {
      font-size: 1.6rem;
      font-weight: 600;
      letter-spacing: -0.02em;
      margin-bottom: 0.9rem;
      color: var(--text-primary);
    }
    .tut-section h3 {
      font-size: 1.05rem;
      font-weight: 600;
      margin-bottom: 0.4rem;
      color: var(--text-primary);
    }
    .tut-section p {
      line-height: 1.65;
      color: var(--text-secondary);
      margin-bottom: 0.9rem;
      font-size: 0.95rem;
    }
    .tut-section a { color: var(--teal); text-decoration: none; border-bottom: 1px solid var(--teal-glow); }
    .tut-section a:hover { border-bottom-color: var(--teal); }
    .tut-section code {
      font-family: var(--font-mono);
      font-size: 0.82em;
      background: var(--bg-deep);
      padding: 0.1rem 0.35rem;
      border-radius: 4px;
      color: var(--text-primary);
    }

    .tut-hero { padding-top: 1rem; }
    .tut-eyebrow {
      text-transform: uppercase;
      font-size: 0.7rem;
      letter-spacing: 0.18em;
      color: var(--teal);
      margin-bottom: 0.65rem;
    }
    .tut-hero h1 {
      font-size: 2.4rem;
      font-weight: 600;
      letter-spacing: -0.03em;
      margin-bottom: 0.9rem;
    }
    .tut-lede { font-size: 1.05rem; line-height: 1.65; color: var(--text-secondary); max-width: 60ch; }

    .tut-callout {
      margin-top: 1.5rem;
      padding: 1rem 1.2rem;
      background: var(--teal-glow);
      border-left: 3px solid var(--teal);
      border-radius: var(--radius-sm);
      font-size: 0.92rem;
      line-height: 1.6;
      color: var(--text-primary);
    }
    .tut-callout code { background: var(--bg-surface); }

    .tut-grid-3 {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 1rem;
      margin-top: 0.5rem;
    }
    .tut-grid-2 {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 1rem;
      margin-top: 0.5rem;
    }

    .tut-subhead {
      font-size: 1.1rem;
      font-weight: 600;
      letter-spacing: -0.015em;
      color: var(--text-primary);
      margin-top: 1.75rem;
      margin-bottom: 0.6rem;
    }

    .tut-paths {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 0.85rem;
      margin-top: 0.4rem;
    }
    .tut-path {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 0.95rem 1.1rem;
      border-left: 3px solid var(--violet);
    }
    .tut-path-tag {
      display: inline-block;
      font-family: var(--font-mono);
      font-size: 0.68rem;
      color: var(--violet);
      background: var(--violet-glow);
      padding: 0.15rem 0.5rem;
      border-radius: 4px;
      margin-bottom: 0.45rem;
      letter-spacing: 0.04em;
    }
    .tut-path h3 { font-size: 0.98rem; margin-bottom: 0.35rem; }
    .tut-path p { font-size: 0.88rem; margin-bottom: 0; }
    .tut-card {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 1.1rem 1.15rem;
      box-shadow: var(--shadow-sm);
    }
    .tut-card-kicker {
      text-transform: uppercase;
      font-size: 0.66rem;
      letter-spacing: 0.13em;
      color: var(--teal);
      margin-bottom: 0.5rem;
    }
    .tut-card p { font-size: 0.88rem; margin-bottom: 0; }

    .tut-steps { padding-left: 1.25rem; }
    .tut-steps li {
      line-height: 1.65;
      color: var(--text-secondary);
      margin-bottom: 0.85rem;
      font-size: 0.95rem;
    }
    .tut-steps li strong { color: var(--text-primary); }

    .tut-pages {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 1rem;
    }
    .tut-page {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 1rem 1.15rem;
    }
    .tut-page-route {
      font-family: var(--font-mono);
      font-size: 0.72rem;
      color: var(--text-muted);
      margin-bottom: 0.5rem;
    }
    .tut-page p { font-size: 0.88rem; margin-bottom: 0; }

    .tut-table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 0.5rem;
      font-size: 0.88rem;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      overflow: hidden;
    }
    .tut-table th, .tut-table td {
      text-align: left;
      padding: 0.7rem 0.95rem;
      border-bottom: 1px solid var(--border);
      vertical-align: top;
    }
    .tut-table thead th {
      background: var(--bg-deep);
      font-weight: 600;
      font-size: 0.78rem;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: var(--text-muted);
    }
    .tut-table tbody tr:last-child td { border-bottom: none; }
    .tut-table td { color: var(--text-secondary); }
    .tut-table code { font-size: 0.8em; }

    .tut-concept {
      margin-top: 1.25rem;
      padding-top: 1.25rem;
      border-top: 1px dashed var(--border);
    }
    .tut-concept:first-of-type { border-top: none; padding-top: 0; margin-top: 0.5rem; }

    .tut-journey {
      margin-top: 1.25rem;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 1.1rem 1.25rem;
    }
    .tut-journey-tag {
      display: inline-block;
      font-family: var(--font-mono);
      font-size: 0.7rem;
      color: var(--teal);
      background: var(--teal-glow);
      padding: 0.15rem 0.5rem;
      border-radius: 4px;
      margin-bottom: 0.5rem;
    }
    .tut-journey h3 { margin-bottom: 0.6rem; }
    .tut-journey ol { padding-left: 1.25rem; }
    .tut-journey li {
      line-height: 1.6;
      color: var(--text-secondary);
      font-size: 0.92rem;
      margin-bottom: 0.45rem;
    }

    .tut-code {
      background: var(--bg-deep);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 1rem 1.15rem;
      font-family: var(--font-mono);
      font-size: 0.82rem;
      line-height: 1.55;
      overflow-x: auto;
      margin-bottom: 1rem;
      color: var(--text-primary);
    }
    .tut-code code { background: none; padding: 0; font-size: inherit; }

    .tut-list { padding-left: 1.25rem; }
    .tut-list li {
      line-height: 1.6;
      color: var(--text-secondary);
      font-size: 0.92rem;
      margin-bottom: 0.5rem;
    }
    .tut-list-inline {
      list-style: none;
      padding: 0.4rem 0 0;
      margin: 0;
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem 1rem;
    }
    .tut-list-inline li {
      font-size: 0.88rem;
      color: var(--text-secondary);
    }

    .tut-details {
      margin: 0.5rem 0 0.5rem;
      padding: 0.6rem 0.85rem;
      background: var(--bg-mid);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      font-size: 0.88rem;
    }
    .tut-details summary {
      cursor: pointer;
      font-weight: 500;
      color: var(--text-secondary);
      list-style: none;
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    .tut-details summary::-webkit-details-marker { display: none; }
    .tut-details summary::before {
      content: '▸';
      font-size: 0.75rem;
      color: var(--text-muted);
      transition: transform 0.15s;
      display: inline-block;
    }
    .tut-details[open] summary::before { transform: rotate(90deg); }
    .tut-details summary:hover { color: var(--text-primary); }
    .tut-details p {
      margin-top: 0.55rem;
      margin-bottom: 0;
      font-size: 0.88rem;
      line-height: 1.6;
      color: var(--text-secondary);
    }

    .tut-list-tight {
      list-style: disc;
      padding-left: 1.1rem;
      margin-top: 0.35rem;
      margin-bottom: 0;
    }
    .tut-list-tight li {
      font-size: 0.9rem;
      line-height: 1.55;
      color: var(--text-secondary);
      margin-bottom: 0.25rem;
    }

    .tut-ops-toc {
      display: flex;
      flex-wrap: wrap;
      gap: 0.4rem;
      margin: 0.75rem 0 1.5rem;
      padding: 0.6rem 0.75rem;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      background: var(--bg-surface);
    }
    .tut-ops-toc a {
      padding: 0.25rem 0.65rem;
      font-size: 0.82rem;
      color: var(--text-secondary);
      text-decoration: none;
      border-radius: var(--radius-sm);
      border-bottom: none;
      transition: background 0.15s, color 0.15s;
    }
    .tut-ops-toc a:hover {
      color: var(--teal);
      background: var(--teal-glow);
    }

    .tut-section-finish { text-align: center; padding-top: 2.5rem; }
    .tut-section-finish h2 {
      font-size: 1.9rem;
      letter-spacing: -0.025em;
    }
    .tut-section-finish .tut-lede { margin: 0 auto; }

    @media (max-width: 880px) {
      .tut-layout { grid-template-columns: 1fr; gap: 1.25rem; padding: 1.5rem 1.1rem 4rem; }
      .tut-toc { position: static; max-height: none; }
      .tut-grid-3 { grid-template-columns: 1fr; }
      .tut-grid-2 { grid-template-columns: 1fr; }
      .tut-paths { grid-template-columns: 1fr; }
      .tut-pages { grid-template-columns: 1fr; }
      .tut-hero h1 { font-size: 1.9rem; }
    }
    """
  end
end
