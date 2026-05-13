defmodule RhoWeb.TutorialLive do
  @moduledoc """
  Public tutorial page introducing newcomers to Rho — what it is, what's on
  the screen, the agents that ship with it, and the user paths that exercise
  the system end-to-end.

  Lives at `/tutorial` under the public scope so visitors can read it without
  an account.
  """

  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :active_section, "welcome")}
  end

  @impl true
  def handle_event("focus_section", %{"id" => id}, socket) do
    {:noreply, assign(socket, :active_section, id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= tutorial_style_tag() %>

    <div class="tut-shell">
      <header class="tut-topbar">
        <a href="/" class="tut-logo">rho</a>
        <nav class="tut-topnav">
          <a href="/users/log_in" class="tut-topnav-link">Sign in</a>
          <a href="/users/register" class="tut-topnav-link tut-topnav-cta">Create account</a>
        </nav>
      </header>

      <div class="tut-layout">
        <aside class="tut-toc">
          <div class="tut-toc-title">On this page</div>
          <ol>
            <%= for {id, label} <- sections() do %>
              <li>
                <a
                  href={"#" <> id}
                  class={if @active_section == id, do: "tut-toc-link tut-toc-link-active", else: "tut-toc-link"}
                  phx-click="focus_section"
                  phx-value-id={id}
                ><%= label %></a>
              </li>
            <% end %>
          </ol>
          <div class="tut-toc-foot">
            Take ~10 minutes. By the end you'll know what every screen does and how to drive Rho yourself.
          </div>
        </aside>

        <main class="tut-content">
          <section id="welcome" class="tut-section tut-hero">
            <div class="tut-eyebrow">Tutorial</div>
            <h1>Welcome to Rho.</h1>
            <p class="tut-lede">
              Rho is an AI agent platform you can drive from a chat window or
              from a guided wizard. It runs LLM-powered agents that hold
              conversations, call tools, share state through editable tables,
              and hand work off to one another. This page is a tour for
              first-time users and developers.
            </p>
            <div class="tut-callout">
              <strong>If you just want to try it:</strong>
              <a href="/users/register">create an account</a>,
              pick or create an organization, then head to <code>Chat</code>
              and say <em>"help me build a skill framework for backend engineers."</em>
              Everything else on this page makes more sense after you've done that once.
            </div>
          </section>

          <section id="big-picture" class="tut-section">
            <h2>The big picture</h2>
            <p>
              Rho is built as an Elixir <strong>umbrella</strong> with five apps,
              organized into three planes. You don't need to memorize this, but
              it's the vocabulary the rest of the tour uses.
            </p>
            <div class="tut-grid-3">
              <div class="tut-card">
                <div class="tut-card-kicker">Execution plane</div>
                <h3>The agent loop</h3>
                <p>
                  An agent runs as a GenServer that loops: read context,
                  call an LLM, parse the response, run a tool, append to a
                  <em>tape</em>, repeat. This lives in <code>apps/rho</code>.
                </p>
              </div>
              <div class="tut-card">
                <div class="tut-card-kicker">Coordination plane</div>
                <h3>Agents talking to agents</h3>
                <p>
                  An event bus and registry let one agent spawn or message
                  others — the foundation for delegation, hiring committees,
                  and any multi-agent workflow.
                </p>
              </div>
              <div class="tut-card">
                <div class="tut-card-kicker">Edge plane</div>
                <h3>How you reach it</h3>
                <p>
                  The Phoenix app you're using right now (<code>apps/rho_web</code>)
                  is one edge. Mix tasks (<code>mix rho.run</code>) are another.
                  Both wrap the same core.
                </p>
              </div>
            </div>
          </section>

          <section id="first-steps" class="tut-section">
            <h2>First steps</h2>
            <ol class="tut-steps">
              <li>
                <strong>Register or sign in.</strong>
                <a href="/users/register">/users/register</a> creates an account.
                Each new user gets a <em>personal</em> organization automatically,
                so you can start immediately without inviting anyone.
              </li>
              <li>
                <strong>Pick an organization.</strong> The home page (<code>/</code>)
                lists every organization you belong to. Click one to enter it,
                or create a new shared org for a team.
              </li>
              <li>
                <strong>Start in Chat.</strong> Every org has a chat workspace at
                <code>/orgs/&lt;slug&gt;/chat</code>. That's where the rest of the
                product is one message away.
              </li>
            </ol>
          </section>

          <section id="pages" class="tut-section">
            <h2>What's on each page</h2>
            <p>
              Once you're inside an organization, the top nav exposes five
              destinations. Here's what each one is for.
            </p>
            <div class="tut-pages">
              <div class="tut-page">
                <div class="tut-page-route">/chat</div>
                <h3>Chat</h3>
                <p>
                  The main canvas. Talk to an agent in natural language,
                  upload files, watch tool calls stream, fork past messages,
                  switch between threads, and add subagents to the workspace.
                  Your session persists across page changes — leaving Chat
                  doesn't reset the conversation.
                </p>
              </div>
              <div class="tut-page">
                <div class="tut-page-route">/libraries · /libraries/:id</div>
                <h3>Libraries</h3>
                <p>
                  A skill library is a structured taxonomy: <em>category →
                  cluster → skill</em>, optionally with proficiency levels.
                  Libraries can be drafts, published versions, or archived.
                  You can fork one, diff two, or open the inline chat overlay
                  to ask an agent about what you're looking at.
                </p>
              </div>
              <div class="tut-page">
                <div class="tut-page-route">/roles · /roles/:id</div>
                <h3>Roles</h3>
                <p>
                  A role profile says <em>"this job needs these skills at
                  these levels."</em> The list page supports semantic search
                  ("a backend engineer who knows distributed systems"); the
                  detail page renders the role's required skills grouped by
                  proficiency.
                </p>
              </div>
              <div class="tut-page">
                <div class="tut-page-route">/flows/:flow_id</div>
                <h3>Flows</h3>
                <p>
                  A flow is a wizard — a fixed graph of steps (form, action,
                  table review, selection) that walks you through a workflow
                  the chat agent could also drive. The flagship flow is
                  <strong>create-framework</strong>. Pick <em>Guided</em> mode
                  for a linear path, <em>Copilot</em> to see the agent's
                  reasoning, or <em>Open</em> to expose every tool call.
                </p>
              </div>
              <div class="tut-page">
                <div class="tut-page-route">/settings · /members</div>
                <h3>Settings &amp; Members</h3>
                <p>
                  Edit your profile and the org's metadata; invite teammates;
                  change roles; transfer ownership. Owners can delete the
                  organization here.
                </p>
              </div>
              <div class="tut-page">
                <div class="tut-page-route">/admin/llm</div>
                <h3>Admin (LLM admission)</h3>
                <p>
                  An operator dashboard that shows live LLM-slot utilization,
                  queue depth, and an event feed from the admission controller.
                  Auto-refreshes once a second.
                </p>
              </div>
            </div>
          </section>

          <section id="agents" class="tut-section">
            <h2>Meet the agents</h2>
            <p>
              Agents are configured in <code>.rho.exs</code> at the project root.
              Each has its own model, system prompt, plugin list, and turn
              strategy. The seven that ship today:
            </p>
            <table class="tut-table">
              <thead>
                <tr><th>Agent</th><th>What it's for</th><th>Notable plugins</th></tr>
              </thead>
              <tbody>
                <tr>
                  <td><code>default</code></td>
                  <td>General-purpose coordinator. Delegates subtasks to other agents and stitches results back together.</td>
                  <td>multi_agent, skills, journal, live_render</td>
                </tr>
                <tr>
                  <td><code>spreadsheet</code></td>
                  <td>The skill-framework editor. Owns library and role-profile workflows: create, import, edit, dedup, merge, publish.</td>
                  <td>data_table, skills, RhoFrameworks.Plugin, uploads, doc_ingest</td>
                </tr>
                <tr>
                  <td><code>data_extractor</code></td>
                  <td>Sub-agent. Reads a PDF / Excel / Word file and returns structured JSON for the parent to import.</td>
                  <td>doc_ingest</td>
                </tr>
                <tr>
                  <td><code>coder</code></td>
                  <td>A senior-Elixir-engineer persona with filesystem and shell tools. Good for refactors, bug fixes, exploration.</td>
                  <td>bash, fs_read, fs_write, fs_edit, step_budget</td>
                </tr>
                <tr>
                  <td><code>researcher</code></td>
                  <td>Concise research helper that cites sources.</td>
                  <td>multi_agent</td>
                </tr>
                <tr>
                  <td><code>technical_evaluator</code></td>
                  <td>Hiring-committee role: scores candidates on coding and system design.</td>
                  <td>multi_agent (messaging only), journal</td>
                </tr>
                <tr>
                  <td><code>culture_evaluator</code> · <code>compensation_evaluator</code></td>
                  <td>Hiring-committee peers — culture fit, salary fit. Push back on each other in shared threads.</td>
                  <td>multi_agent (messaging only), journal</td>
                </tr>
              </tbody>
            </table>
          </section>

          <section id="concepts" class="tut-section">
            <h2>Core concepts</h2>

            <div class="tut-concept">
              <h3>Sessions</h3>
              <p>
                A <strong>session</strong> is the container for a conversation
                with one or more agents. It holds the primary agent, any
                subagents, the message history, the data tables, and the event
                subscriptions. Visiting <code>/chat</code> ensures a session
                exists; visiting <code>/chat/&lt;id&gt;</code> rehydrates one.
              </p>
            </div>

            <div class="tut-concept">
              <h3>Tapes</h3>
              <p>
                Every semantic event — user message, LLM response, tool call,
                tool result — gets appended to a tape. Tapes are forensic
                (they let you trace why an agent did what it did) and they
                drive context reconstruction across compaction. They are <em>not</em>
                used to resume a paused agent; live state is in the agent
                process.
              </p>
            </div>

            <div class="tut-concept">
              <h3>Plugins, transformers, and tools</h3>
              <p>
                A <strong>plugin</strong> contributes one or more of: <em>tools</em>
                the agent can call, <em>prompt sections</em> the system message
                exposes, and <em>bindings</em> for inter-agent messaging. A
                <strong>transformer</strong> is the cross-cutting variant — it
                mutates prompts, responses, tool arguments, or tool results
                as they flow through the loop. Ship-day plugins include
                <code>bash</code>, <code>fs_read</code>, <code>fs_write</code>,
                <code>fs_edit</code>, <code>web_fetch</code>, <code>python</code>,
                <code>data_table</code>, <code>uploads</code>, <code>doc_ingest</code>,
                <code>multi_agent</code>, <code>skills</code>,
                <code>live_render</code>, <code>step_budget</code>, and
                <code>journal</code>.
              </p>
            </div>

            <div class="tut-concept">
              <h3>Skills</h3>
              <p>
                A <strong>skill</strong> is a named markdown workflow the agent
                loads on demand with <code>skill(name: "create-framework")</code>.
                It's the difference between teaching the model the full
                procedure in the system prompt (expensive) and pulling the
                instructions in only when needed (cheap). Skills are stored
                under each agent's workspace and can be preloaded in
                <code>.rho.exs</code> via <code>&#123;:skills, preload: ["..."]&#125;</code>.
              </p>
            </div>

            <div class="tut-concept">
              <h3>Data tables</h3>
              <p>
                Tables are how the agent and the UI share editable structured
                data. There's a permissive <code>main</code> table by default
                and domain-specific named tables like <code>library:&lt;name&gt;</code>
                and <code>role_profile</code> with strict schemas. The
                LiveView reads from the same in-process server the agent
                writes to, so what the agent generates appears in your
                browser in real time — and your edits are visible to the
                agent on its next turn.
              </p>
            </div>

            <div class="tut-concept">
              <h3>Turn strategies</h3>
              <p>
                The inner turn of the loop is pluggable. <code>:direct</code>
                lets the LLM emit tool calls in its provider's native format.
                <code>:typed_structured</code> generates a BAML schema with a
                discriminated union of action types (<em>respond</em>,
                <em>think</em>, <em>tool</em>) and forces the model to emit a
                single well-typed action per step — that's what the
                <code>spreadsheet</code> agent uses to stay disciplined.
              </p>
            </div>
          </section>

          <section id="journeys" class="tut-section">
            <h2>Four user journeys</h2>
            <p>
              The fastest way to internalize Rho is to walk through what
              actually happens behind a click.
            </p>

            <div class="tut-journey">
              <div class="tut-journey-tag">Journey 1</div>
              <h3>Chat with the general assistant</h3>
              <ol>
                <li>Sign in and land on the org picker; click into your personal org.</li>
                <li>Open the Chat page. A new conversation is ready with the general-purpose assistant selected.</li>
                <li>Type whatever you're trying to do in plain language.</li>
                <li>Watch the agent work. It narrates its thinking, fires off any tools it needs, and shows you the results in line.</li>
                <li>For bigger questions it can delegate to a research sub-agent and wait for its answer before continuing.</li>
                <li>Forked from any past message to try a different direction without losing the original branch.</li>
              </ol>
            </div>

            <div class="tut-journey">
              <div class="tut-journey-tag">Journey 2</div>
              <h3>Build a skill framework with a guided flow</h3>
              <ol>
                <li>From the Libraries page click <em>New framework</em>.</li>
                <li>The first screen asks you to pick a starting point — scratch, similar role, extend, or merge. Pick one and continue.</li>
                <li>Fill the intake form for that path: name, description, domain, target roles, skill count, level count.</li>
                <li>The wizard does background research, generates a skill skeleton, then fills in proficiency descriptions in parallel.</li>
                <li>You review the generated table, edit inline, and resolve anything the wizard flagged.</li>
                <li>The final step saves the library as a draft. You can publish it as a frozen version whenever you're ready.</li>
              </ol>
            </div>

            <div class="tut-journey">
              <div class="tut-journey-tag">Journey 3</div>
              <h3>Score candidates against a role profile</h3>
              <ol>
                <li>Open the Roles page and click into the role you're hiring for.</li>
                <li>Start a chat there and ask the assistant to evaluate a candidate against this role.</li>
                <li>The agent reads the role's required skills and levels and sets up a scorecard.</li>
                <li>Drop in the candidate's resume, transcript, or interview notes; the agent fills the scorecard.</li>
                <li>For deeper evaluation it can convene a small hiring committee — a technical evaluator, a culture evaluator, and a compensation evaluator working in parallel — then synthesize their scores.</li>
              </ol>
            </div>

            <div class="tut-journey">
              <div class="tut-journey-tag">Journey 4</div>
              <h3>Import a spreadsheet as a skill library</h3>
              <ol>
                <li>Drag an <code>.xlsx</code> or <code>.csv</code> into the chat window. Rho stores it as an upload and shows a <em>"Detected: …"</em> hint.</li>
                <li>For a clean single-library file, the agent imports it with sensible defaults — rows stream into a new tab in the data panel.</li>
                <li>For a multi-sheet file (one role per sheet) the agent offers to import each sheet as its own library — confirm and it'll work through them all.</li>
                <li>Review the resulting table, edit anything that looks off, then ask the agent to save (once per library, if there's more than one).</li>
                <li>The new draft library shows up at <code>/libraries</code>.</li>
              </ol>
            </div>
          </section>

          <section id="frameworks" class="tut-section">
            <h2>Create a skill framework</h2>
            <p>
              Skill frameworks are Rho's flagship workflow, so they deserve
              their own walkthrough. A <strong>framework</strong> is a named,
              versioned skill library — a tree of <em>categories → clusters →
              skills</em>, each skill with a description and (optionally) a
              ladder of proficiency levels. The same data structure powers
              role profiles, candidate scoring, and library merges.
            </p>

            <h3 class="tut-subhead">Two entry points</h3>
            <p>
              You can create a framework two ways. They produce the same
              artefact; pick whichever fits the moment.
            </p>
            <div class="tut-grid-2">
              <div class="tut-card">
                <div class="tut-card-kicker">Conversational</div>
                <h3>From Chat</h3>
                <p>
                  Open <code>/chat</code>, switch the active agent to
                  <code>spreadsheet</code>, and describe the framework you
                  want. The agent loads the <code>create-framework</code>
                  skill on demand and drives the workflow turn by turn. Best
                  when your inputs are messy or you want to iterate.
                </p>
              </div>
              <div class="tut-card">
                <div class="tut-card-kicker">Guided</div>
                <h3>From a Wizard</h3>
                <p>
                  Click <em>New framework</em> on the Libraries page (or go
                  directly to <code>/orgs/&lt;slug&gt;/flows/create-framework</code>).
                  The wizard walks you through a fixed sequence of forms,
                  table reviews, and explicit confirmation gates. Best when
                  you want rails — every input is validated and you can see
                  exactly where you are.
                </p>
              </div>
            </div>

            <h3 class="tut-subhead">The four paths</h3>
            <p>
              Whichever entry point you pick, the workflow recognises four
              starting points. The agent (or the wizard's first form) asks
              you to choose one.
            </p>
            <div class="tut-paths">
              <div class="tut-path">
                <div class="tut-path-tag">Path A</div>
                <h3>From scratch</h3>
                <p>
                  Nothing to anchor on — you just name a domain and roles
                  and let the LLM generate the skeleton. Best when no
                  similar framework exists in your org yet. Most intake
                  questions (purpose, level count, must-haves) belong here.
                </p>
              </div>
              <div class="tut-path">
                <div class="tut-path-tag">Path B</div>
                <h3>Seeded by similar roles</h3>
                <p>
                  Rho searches your existing role profiles for matches and
                  shows you a candidate list. You pick which to use as
                  inspiration; the LLM expands their skills into a fresh
                  framework. Best when your org already has role profiles
                  the new framework should overlap with.
                </p>
              </div>
              <div class="tut-path">
                <div class="tut-path-tag">Path C</div>
                <h3>Inspired by a library</h3>
                <p>
                  You name an existing library (e.g. SFIA, AICB) as
                  <em>reference only</em> — the agent reads its categories,
                  cluster style, and level model and adapts that pattern to
                  your new domain. The reference library is not copied.
                </p>
              </div>
              <div class="tut-path">
                <div class="tut-path-tag">Path D</div>
                <h3>Compose from named roles in a library</h3>
                <p>
                  You name specific roles and a specific source library
                  ("combine Risk Analyst and Compliance Officer from ESCO").
                  The agent unions those roles' skills with exact-id dedup
                  — no LLM generation, no rewording, just a literal merge.
                  Best for curated upstream taxonomies.
                </p>
              </div>
            </div>

            <h3 class="tut-subhead">Walking Path A in chat (recommended first try)</h3>
            <p>
              Here's the most newcomer-friendly version, blow by blow.
              Open the Chat page and switch the active agent to the
              <strong>Skill Framework Editor</strong> (labelled
              <code>spreadsheet</code> in the agent picker) — the default
              general-purpose agent won't run this workflow.
            </p>
            <ol class="tut-steps">
              <li>
                <strong>Tell the agent what you want.</strong> Try a
                sentence like: <em>"I want to build a skill framework for
                backend engineers in fintech, from scratch."</em> The
                agent recognises this as the from-scratch path and starts
                a short intake.
              </li>
              <li>
                <strong>Answer the intake questions.</strong> You'll be
                asked for whatever the agent can't reasonably infer:
                industry, role(s), purpose (hiring vs. L&amp;D vs. career
                pathing), how many proficiency levels you want (default
                five), and any must-have competencies. Two or three
                sentences is plenty — you don't have to fill every field.
              </li>
              <li>
                <strong>Watch the skeleton appear.</strong> A new tab
                shows up in the data panel on the right and fills with
                rows: categories, clusters, skill names, one-sentence
                descriptions. The agent narrates progress; don't interrupt
                while rows are streaming in. When the count settles,
                you'll get a short summary.
              </li>
              <li>
                <strong>Review and edit.</strong> Click into any cell to
                rename, rewrite, or delete it. Or just say what you want
                changed — <em>"Drop the 'DevOps' cluster"</em> or
                <em>"Add a skill for distributed tracing under
                Observability"</em> — and the agent will edit the table
                for you.
              </li>
              <li>
                <strong>Approve proficiency generation.</strong> Once
                you're happy with the skeleton, say <em>"go ahead"</em>
                or <em>"generate proficiency levels."</em> This is the
                expensive step — the agent fans out across categories in
                parallel and fills each skill with level-by-level
                descriptions. Give it 30–60 seconds.
              </li>
              <li>
                <strong>Save.</strong> Tell the agent to save when you're
                ready. The framework is persisted as a <strong>draft</strong>
                and appears on the Libraries page. It stays editable;
                publishing it as a frozen version is a separate step
                (see below).
              </li>
            </ol>
            <div class="tut-callout">
              <strong>If the chat seems to pause when it shouldn't,</strong>
              just say <em>"keep going."</em> The agent works one step at
              a time and occasionally waits for you when it didn't need to;
              a nudge gets the loop moving again.
            </div>
            <details class="tut-details">
              <summary>Behind the scenes (for developers)</summary>
              <p>
                The Path A chat walkthrough runs roughly these tools in
                order: <code>generate_framework_skeletons</code> (writes
                rows into a workspace table named <code>library:&lt;your
                name&gt;</code>), then <code>generate_proficiency</code>
                (parallel category writers), then
                <code>save_framework</code> (persists as a draft library
                under your org).
              </p>
            </details>

            <h3 class="tut-subhead">Walking the wizard</h3>
            <p>
              If you'd rather follow rails, open the
              <strong>Create Skill Framework</strong> wizard from the
              Libraries page (or go directly to
              <code>/orgs/&lt;slug&gt;/flows/create-framework</code>).
              You'll move through these screens in order for the
              from-scratch path:
            </p>
            <ul class="tut-list">
              <li>
                <strong>Pick a Starting Point.</strong> A single-choice
                form — scratch / from a similar role / extend an existing
                framework / merge two existing frameworks. Picking
                <em>scratch</em> routes you to the next screen.
              </li>
              <li>
                <strong>Intake.</strong> A short form asking for the
                framework's name, description, domain, target roles, how
                many skills to aim for, and how many proficiency levels.
                Every field is validated before you can continue.
              </li>
              <li>
                <strong>Research.</strong> The wizard does background
                research on your domain and shows the findings as pinned
                cards. Unpin anything irrelevant or add your own notes,
                then continue.
              </li>
              <li>
                <strong>Generate &amp; Review.</strong> The wizard
                generates the framework skeleton into a data table and
                hands it back to you. Edit inline, add or remove rows,
                then approve.
              </li>
              <li>
                <strong>Confirm &amp; Proficiency.</strong> A confirmation
                gate (so you don't accidentally trigger the slow step),
                then the wizard fills in proficiency level descriptions.
              </li>
              <li>
                <strong>Save.</strong> The new draft library is created
                under your org and the wizard hands you off to its detail
                page.
              </li>
            </ul>
            <p>
              The wizard has three modes you can toggle at the top of the
              page: <strong>Guided</strong> hides reasoning (the cleanest
              view), <strong>Copilot</strong> shows the agent's thinking on
              AI-driven steps, and <strong>Open</strong> exposes everything
              — useful when a step doesn't look right and you want to see
              what the agent saw.
            </p>

            <h3 class="tut-subhead">Publishing, versions, and defaults</h3>
            <p>
              Saving always produces a <strong>draft</strong> — fully
              editable, easy to undo. Locking it in is a separate step
              you have to ask for; Rho never publishes on your behalf.
            </p>
            <ol class="tut-steps">
              <li>
                <strong>Publish when ready.</strong> Say something like
                <em>"publish the Backend Engineering library as v1."</em>
                The agent freezes the current rows as a version (v1, v2,
                etc.). Published versions are immutable.
              </li>
              <li>
                <strong>Switch the default.</strong> If a library has
                more than one published version, you can set which one
                is returned by default. Ask the agent to <em>"set v2 as
                the default for Backend Engineering"</em> and it'll
                handle the flip.
              </li>
              <li>
                <strong>Edit later.</strong> Editing a published version
                opens a new draft on top of it — the published version
                stays untouched. When you're happy, publish again to
                make a new version.
              </li>
            </ol>
            <details class="tut-details">
              <summary>Behind the scenes (for developers)</summary>
              <p>
                Publishing goes through
                <code>manage_library(action: "publish", library_id: &lt;draft-uuid&gt;)</code>,
                which auto-tags the new version (<code>YYYY.N</code>
                unless you pass <code>version_tag</code>). Switching the
                default goes through
                <code>library_versions(action: "set_default", library_id: &lt;version-uuid&gt;)</code>;
                drafts can't be defaults, only published versions can.
              </p>
            </details>

            <p>
              Once a framework exists you'll want to import existing data
              into it, deduplicate noisy skills, merge it with another
              library, or attach role profiles. Those workflows have their
              own dedicated section below.
            </p>
          </section>

          <section id="library-ops" class="tut-section">
            <h2>Library operations</h2>
            <p>
              Creating a framework is one workflow; the other half of the
              product is what you do with it afterwards. Five operations
              cover the rest of the library lifecycle. All of them live in
              chat — switch to the <strong>Skill Framework Editor</strong>
              and describe what you want.
            </p>

            <div class="tut-ops-toc">
              <a href="#op-import">Importing</a>
              <a href="#op-edit">Editing &amp; publishing</a>
              <a href="#op-dedup">Deduplicating</a>
              <a href="#op-merge">Merging libraries</a>
              <a href="#op-roles">Role profiles</a>
            </div>

            <h3 id="op-import" class="tut-subhead">Importing an existing framework</h3>
            <p>
              When the data already lives somewhere — a spreadsheet, a
              built-in template, a document — you want to <em>import</em>
              it rather than have Rho invent it. Three flavours, all
              triggered by what you say or drop into chat.
            </p>
            <p><strong>From a built-in template (SFIA v8).</strong></p>
            <ol class="tut-steps">
              <li>
                Say <em>"load SFIA v8 as my starting library."</em> The
                agent pulls every SFIA skill into a fresh tab in the data
                panel.
              </li>
              <li>
                Trim it however you like. You can ask the agent to
                <em>"drop the Strategy category"</em> or
                <em>"remove these three skills"</em>, or click rows in
                the table and delete them yourself.
              </li>
              <li>
                Tell the agent to save. A new draft library is created
                under your org. The built-in SFIA template stays
                untouched — your draft is independent.
              </li>
            </ol>
            <p><strong>From an Excel or CSV.</strong></p>
            <ol class="tut-steps">
              <li>
                Drag the file into the chat input (or use the upload
                button). Rho looks at the shape and writes a
                <em>"Detected: …"</em> line into the conversation.
              </li>
              <li>
                The agent picks a branch based on what it found.
                <ul class="tut-list-tight">
                  <li>
                    <em>Single library:</em> imports directly with the
                    columns it detected.
                  </li>
                  <li>
                    <em>One sheet per role:</em> offers you two options
                    in plain English — either flatten the sheets into
                    one file yourself, or let the agent import each
                    sheet as its own library. Pick the latter and it'll
                    work through them in one pass.
                  </li>
                  <li>
                    <em>Ambiguous:</em> asks you for the library name
                    before importing.
                  </li>
                </ul>
              </li>
              <li>
                Once the rows land in the panel, review and save as a
                draft — same as the SFIA path.
              </li>
            </ol>
            <p><strong>What your spreadsheet should look like.</strong></p>
            <p>
              Header names don't have to match exactly — Rho normalizes
              case and punctuation, so <code>Skill_Name</code>,
              <code>skill name</code>, and <code>SKILL NAME</code> are
              all equivalent. Only the skill-name column is required;
              everything else is optional with sensible fallbacks.
            </p>
            <table class="tut-table">
              <thead>
                <tr>
                  <th>Column</th>
                  <th>Accepted headers</th>
                  <th>If missing</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td><strong>Skill name</strong> (required)</td>
                  <td><code>Skill Name</code>, <code>Skill</code>, <code>Competency</code>, <code>Competence</code></td>
                  <td>Import is refused</td>
                </tr>
                <tr>
                  <td>Skill description</td>
                  <td><code>Skill Description</code>, <code>Description</code>, <code>Definition</code>, <code>What it means</code></td>
                  <td>Left blank</td>
                </tr>
                <tr>
                  <td>Category</td>
                  <td><code>Category</code>, <code>Domain</code>, <code>Area</code>, <code>Group</code></td>
                  <td>"Uncategorized"</td>
                </tr>
                <tr>
                  <td>Cluster (sub-category)</td>
                  <td><code>Cluster</code>, <code>Sub-category</code>, <code>Sub-domain</code>, <code>Subgroup</code></td>
                  <td>Same value as Category</td>
                </tr>
                <tr>
                  <td>Library name<br /><small>(multi-library files)</small></td>
                  <td><code>Skill Library Name</code>, <code>Library Name</code>, <code>Library</code>, <code>Framework Name</code></td>
                  <td>File name becomes the library name; one library per file</td>
                </tr>
              </tbody>
            </table>
            <p>
              <strong>Adding proficiency levels.</strong> If you want the
              imported framework to ship with proficiency descriptions,
              include one row per <em>(skill, level)</em> combination
              and add these columns. Rho groups rows by skill name and
              orders the levels numerically.
            </p>
            <table class="tut-table">
              <thead>
                <tr>
                  <th>Column</th>
                  <th>Accepted headers</th>
                  <th>What it should hold</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td>Level number</td>
                  <td><code>Level</code>, <code>Lvl</code>, <code>Lv</code>, <code>Proficiency Level</code>, <code>Proficiency</code>, <code>Tier</code>, <code>Rank</code></td>
                  <td>An integer — 1, 2, 3…</td>
                </tr>
                <tr>
                  <td>Level name</td>
                  <td><code>Level Name</code>, <code>Tier Name</code>, <code>Rank Name</code>, <code>Proficiency Name</code></td>
                  <td>A short label — "Novice", "Practitioner"…</td>
                </tr>
                <tr>
                  <td>Level description</td>
                  <td><code>Level Description</code>, <code>Tier Description</code>, <code>Indicator</code>, <code>Behavior</code>, <code>Behaviour</code></td>
                  <td>What someone at that level can do</td>
                </tr>
              </tbody>
            </table>
            <p>
              <strong>File shapes Rho recognises.</strong>
            </p>
            <ul class="tut-list">
              <li>
                <strong>Single sheet, single library</strong> — the
                common case. One skill per row, or several rows per
                skill if you include proficiency levels.
              </li>
              <li>
                <strong>Single sheet, multiple libraries</strong> — add
                a <code>Skill Library Name</code> column and Rho splits
                rows into one library per distinct value in that
                column.
              </li>
              <li>
                <strong>Multiple sheets, one library per sheet</strong>
                — each sheet has the same columns and no library-name
                column. Rho recognises this shape and offers to import
                each sheet as its own library, using the sheet name as
                the library name.
              </li>
            </ul>
            <p><strong>Limits and edge cases:</strong></p>
            <ul class="tut-list">
              <li>The first <strong>1,000 rows</strong> of a sheet are imported. Larger files need splitting today.</li>
              <li>Rows with a blank skill name are dropped silently.</li>
              <li>If a library with the resolved name already exists in your org, the import is refused — rename your file (or the column value) and try again.</li>
              <li>If a file has multiple sheets with <em>different</em> columns, Rho can't guess what you mean and will ask you to specify the library name explicitly.</li>
            </ul>

            <p><strong>From a PDF or Word doc.</strong></p>
            <p>
              Drop the file into chat and ask the agent to import it. It
              delegates to a small extractor sub-agent that pulls
              structured data out of the document and hands it back for
              import. PDF parsing is partial in v1 — for now, prefer
              Excel/CSV exports of your source document.
            </p>
            <div class="tut-callout">
              <strong>One handy rule:</strong> always let the agent
              import a structured file — don't paste the contents in
              and ask it to "add these rows" manually. The structured
              importer maps spreadsheet columns to the library schema
              correctly; pasted rows often misalign.
            </div>
            <details class="tut-details">
              <summary>Behind the scenes (for developers)</summary>
              <p>
                Built-in templates load via
                <code>load_library(template_key: "sfia_v8")</code> into a
                workspace table named <code>library:sfia_v8</code>.
                Spreadsheet uploads route through
                <code>import_library_from_upload</code> — once for a
                single-library file, once per <code>sheet:</code> +
                <code>library_name:</code> for a multi-sheet file.
                Document uploads go through
                <code>delegate_task(role: "data_extractor", …)</code>
                then back into the same importer. The save step is
                <code>save_framework(table: "library:&lt;name&gt;")</code>
                in all cases.
              </p>
            </details>

            <h3 id="op-edit" class="tut-subhead">Editing &amp; publishing a saved library</h3>
            <p>
              Saved libraries follow a strict <strong>draft → published
              versions → default</strong> lifecycle. Every transition is
              explicit — Rho never publishes or changes the default on
              its own.
            </p>
            <ol class="tut-steps">
              <li>
                <strong>Load it.</strong> Tell the agent <em>"load the
                HR Manager library."</em> It opens whichever version
                makes sense (draft if you have one, otherwise the
                default published version) in a tab on the right.
              </li>
              <li>
                <strong>Edit.</strong> Click cells to edit them, or just
                describe the change in chat — <em>"rewrite the
                'Stakeholder Management' description in plain English"</em>
                or <em>"add a skill for 1:1 coaching under People
                Leadership."</em> The agent reads the current row before
                rewriting, so it won't invent prior content.
              </li>
              <li>
                <strong>Save.</strong> Ask the agent to save. The
                changes always go into a <strong>draft</strong>. If you
                only had a published version, the agent automatically
                opens a fresh draft on top of it — the published version
                stays frozen.
              </li>
              <li>
                <strong>Publish when you're ready.</strong> Say
                <em>"publish this as v2."</em> The draft is promoted to
                the next published version and locked in.
              </li>
              <li>
                <strong>Switch the default.</strong> Once you have more
                than one published version, ask the agent <em>"set v2
                as the default."</em> Future loads will return v2 unless
                a specific version is asked for.
              </li>
            </ol>
            <div class="tut-callout">
              <strong>Publishing is irreversible</strong> — the version
              is frozen forever. So is changing the default. The agent
              never does either on its own; you have to ask.
            </div>
            <details class="tut-details">
              <summary>Behind the scenes (for developers)</summary>
              <p>
                Loading uses
                <code>load_library(library_name: "…")</code>; edits go
                through the data-table tools (<code>update_cells</code>,
                <code>edit_row</code>, <code>add_rows</code>,
                <code>delete_rows</code>); saving is
                <code>save_framework(table: "library:&lt;name&gt;")</code>.
                Publish is
                <code>manage_library(action: "publish", library_id: &lt;draft-uuid&gt;)</code>;
                default flips go through
                <code>library_versions(action: "set_default", library_id: &lt;version-uuid&gt;)</code>.
                Versions are auto-tagged <code>YYYY.N</code> unless you
                pass <code>version_tag</code>.
              </p>
            </details>

            <h3 id="op-dedup" class="tut-subhead">Deduplicating within a library</h3>
            <p>
              After enough edits — especially after generation — a
              library can pick up near-duplicate skills ("SQL Queries"
              and "Writing SQL", or two slightly different
              "Stakeholder Management" entries). Rho finds them for
              you and lets you resolve each pair in a review tab.
            </p>
            <ol class="tut-steps">
              <li>
                <strong>Ask for the review.</strong> Say <em>"find
                duplicates in the Backend Engineering library."</em> A
                new <em>Duplicate review</em> tab opens in the data
                panel with candidate pairs side by side. The agent tells
                you the pair count and any cluster summary, but it won't
                spell out the pairs in chat — the table is where you
                work.
              </li>
              <li>
                <strong>Decide on each pair.</strong> For each row, set
                the <em>Resolution</em> column to one of three choices:
                <ul class="tut-list-inline">
                  <li><strong>Keep A</strong> — merge B into A</li>
                  <li><strong>Keep B</strong> — merge A into B</li>
                  <li><strong>Keep both</strong> — they're intentionally different</li>
                </ul>
                Rows you don't touch are left as-is.
              </li>
              <li>
                <strong>Save.</strong> Say <em>"apply"</em> or
                <em>"save the resolutions."</em> Your choices are
                applied to the library and the cleaned version is
                persisted.
              </li>
            </ol>
            <div class="tut-callout">
              <strong>Don't ask for a fresh duplicate search while
              you're mid-review.</strong> Re-running it overwrites the
              review tab and discards every choice you've made. Save
              first, then re-run if you want a second pass.
            </div>
            <details class="tut-details">
              <summary>Behind the scenes (for developers)</summary>
              <p>
                Finding duplicates runs
                <code>dedup_library(library_id: …)</code>, which uses
                cosine similarity plus slug/word heuristics and writes
                pair rows into a <code>dedup_preview</code> table. Each
                row carries a <code>resolution</code> cell with the
                literal values <code>merge_a</code> / <code>merge_b</code>
                / <code>keep_both</code> (corresponding to the buttons
                described above). Save goes through the standard
                <code>save_framework(table: "library:&lt;name&gt;")</code>,
                which reads <code>dedup_preview</code>, applies the
                resolutions, and persists the library.
              </p>
            </details>

            <h3 id="op-merge" class="tut-subhead">Merging multiple saved libraries</h3>
            <p>
              Sometimes you have two libraries that overlap and want one
              clean library that's the union of both. Rho does this in
              two phases — a preview so you can see the conflicts, then
              a commit once you've resolved them.
            </p>
            <ol class="tut-steps">
              <li>
                <strong>Tell the agent what you want.</strong> Say
                something like <em>"merge the HR Manager and People
                Operations libraries into one called People &amp;
                Talent."</em> The agent confirms which libraries it
                found and gets ready to preview.
              </li>
              <li>
                <strong>Save any unsaved drafts first.</strong> If one
                of the libraries you want to merge only exists as a
                workspace tab (it hasn't been saved yet), the agent
                will pause and ask you to save it. Once saved, it
                continues.
              </li>
              <li>
                <strong>Review the preview.</strong> A
                <em>Combine preview</em> tab opens in the data panel.
                Each conflicting skill — same name, different
                descriptions — shows up as a row with A and B values
                side by side and a <em>Keep A</em> / <em>Keep B</em>
                button. The agent tells you the source counts and how
                many conflicts there are; if there are zero conflicts,
                you can skip to the next step.
              </li>
              <li>
                <strong>Resolve conflicts in the table.</strong> Click
                the Keep button for the value you want on each conflict
                row. The agent does not ask you to type resolutions in
                chat — the table is where it happens.
              </li>
              <li>
                <strong>Commit.</strong> Say <em>"proceed"</em> or
                <em>"go ahead and merge."</em> Rho creates the new
                combined library as a draft. It shows up in your
                Libraries list right after.
              </li>
            </ol>
            <div class="tut-callout">
              <strong>This isn't the same as create-framework Path D.</strong>
              Path D clones the literal skills of named <em>roles</em>
              inside one library. This workflow merges the skill rows
              of two or more <em>saved libraries</em>. Pick the one
              that matches the unit you're combining.
            </div>
            <details class="tut-details">
              <summary>Behind the scenes (for developers)</summary>
              <p>
                The agent first runs
                <code>manage_library(action: "list")</code> to find each
                library's UUID (the cross-library tools reject names).
                The preview is
                <code>combine_libraries(source_library_ids_json: […], new_name: "…", commit: false)</code>,
                which populates a <code>combine_preview</code> table.
                Commit is the same call with <code>commit: true</code>
                and <code>resolutions_json: "auto"</code> — note that
                <code>source_library_ids_json</code> and
                <code>new_name</code> are required on the commit call,
                they aren't remembered from the preview.
              </p>
            </details>

            <h3 id="op-roles" class="tut-subhead">Building role profiles</h3>
            <p>
              A <strong>role profile</strong> is a named role plus the
              skills it requires and the level expected for each. It's
              what makes candidate scoring possible — the scorer needs
              to know which skills to weight and how high. There are
              two ways to build one.
            </p>
            <p><strong>Build a new role profile from scratch.</strong></p>
            <ol class="tut-steps">
              <li>
                Tell the agent which library to draw from:
                <em>"build a Backend Engineer role profile from the
                Backend Engineering library."</em> The agent surfaces the
                available skills so you can pick from them.
              </li>
              <li>
                Pick the skills that belong on this role and set a
                required level for each. You can do it in chat
                (<em>"include SQL at level 3 and distributed systems at
                level 4"</em>) or by clicking into the
                <em>Role profile</em> tab in the data panel.
              </li>
              <li>
                Tell the agent to save. The role profile shows up on
                the Roles page and is searchable by name or by
                description.
              </li>
            </ol>
            <p><strong>Clone an existing role profile.</strong></p>
            <ol class="tut-steps">
              <li>
                Describe what you want: <em>"find role profiles
                similar to a backend engineer who knows distributed
                systems."</em> Rho runs a semantic search across your
                org's role profiles and drops the candidates into a
                <em>Role candidates</em> tab in the data panel,
                grouped by your query.
              </li>
              <li>
                <strong>Check the rows you want</strong> in that tab.
                The agent tells you how many matches landed but won't
                list them in chat — the table is the picker.
              </li>
              <li>
                Tell the agent to clone the rows you checked. Several
                rows union their skills into one composite role, which
                is useful when you're trying to assemble a mix of two
                or three real roles.
              </li>
              <li>
                Edit the resulting role profile and save it.
              </li>
            </ol>
            <div class="tut-callout">
              <strong>Want a library, not a profile?</strong> If you
              want the picked roles' skills assembled into a brand new
              <em>library</em> (not a role profile), that's the
              create-framework <em>Path D — compose from named roles in
              a library</em> from earlier in the tutorial. Same setup,
              different end product.
            </div>
            <details class="tut-details">
              <summary>Behind the scenes (for developers)</summary>
              <p>
                Path A (new): the agent runs
                <code>browse_library(library_name: "…")</code> to read
                skills, then <code>manage_role(action: "start_draft")</code>
                to initialize an empty <code>role_profile</code> table,
                then <code>add_rows(table: "role_profile", …)</code>,
                then <code>manage_role(action: "save")</code>. Path B
                (clone): the agent runs
                <code>analyze_role(action: "find_similar", queries_json: "…", [library_id: "…"])</code>
                (results stream into a <code>role_candidates</code>
                tab), waits for you to check rows, then
                <code>manage_role(action: "clone", role_profile_ids_json: "[\"…\"]")</code>
                with the picked UUIDs, edits, and saves.
              </p>
            </details>
          </section>

          <section id="extending" class="tut-section">
            <h2>Extending Rho</h2>
            <p>
              Adding your own agent is mostly a <code>.rho.exs</code> exercise.
              Open the file at the project root and add an entry:
            </p>
            <pre class="tut-code"><code><%= example_agent_config() %></code></pre>
            <p>That's all it takes. The agent is now selectable in chat and
            invokable by other agents. Two things to know:</p>
            <ul class="tut-list">
              <li>
                Atom plugin shorthands (<code>:bash</code>, <code>:fs_read</code>,
                etc.) are mapped in <code>Rho.Stdlib</code>. To pass options use
                the tuple form <code>&#123;:skills, preload: ["..."]&#125;</code>.
              </li>
              <li>
                The default turn strategy is <code>:direct</code>. Switch to
                <code>:typed_structured</code> when you want a single
                discriminated action per turn (better for tool-heavy
                workflows; pricier per token).
              </li>
            </ul>
            <p>
              For deeper extensions — a new tool, a new transformer, a new
              flow — start with <code>apps/rho/lib/rho/plugin.ex</code>,
              <code>apps/rho/lib/rho/transformer.ex</code>, and the existing
              implementations under <code>apps/rho_stdlib/lib/rho/stdlib/plugins/</code>.
              The <code>CLAUDE.md</code> at the project root is the most
              up-to-date map of the codebase.
            </p>
          </section>

          <section id="next" class="tut-section tut-section-finish">
            <h2>You're ready.</h2>
            <p class="tut-lede">
              Now go build something. <a href="/users/register">Create an account</a>
              or <a href="/users/log_in">sign in</a>, head to Chat, and tell
              the agent what you're trying to do.
            </p>
          </section>
        </main>
      </div>
    </div>
    """
  end

  defp sections do
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

  defp tutorial_style_tag do
    {:safe, ["<style>", tutorial_css(), "</style>"]}
  end

  defp example_agent_config do
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

  defp tutorial_css do
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
