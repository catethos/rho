defmodule RhoFrameworks.LLM.MatchFlowIntent do
  @moduledoc """
  BAML-backed classifier that routes a free-form natural-language message
  to a known flow + extracted intake fields.

  Phase 9 of the swappable-decision-policy plan (§3.5). The user types
  e.g. *"create a framework for backend engineers"* into the libraries
  landing page; this classifier returns
  `{flow_id: "create-framework", name: "...", target_roles: "...",
  confidence: 0.9}` and the LV navigates to the wizard with intake
  pre-seeded — no tool loop, one structured-output call.

  ## Output contract

  All fields are required. Non-applicable values are returned as the
  empty string `""` (or the empty list `[]` for `library_hints`) — never
  `null`. This keeps the caller's pattern-matching uniform (everything
  is `is_binary/1` or `is_list/1`).

    * `flow_id` — string, must match a known flow's `id()`
      (`"create-framework"` or `"edit-framework"`) or the literal
      `"unknown"`. Emitted as a string because `RhoBaml.SchemaCompiler`
      does not encode atoms or enums; the caller validates against
      `FlowRegistry.get/1`.
    * `confidence` — `0.0..1.0`. The caller treats `< 0.5` as "stay on
      the landing page and ask the user to refine."
    * `reasoning` — one short sentence the LV can flash if confidence is
      low ("I'm not sure what you meant — got: …").
    * `name`, `description`, `domain`, `target_roles` — extracted intake
      fields. Empty string when the message doesn't contain them.
    * `starting_point` — applies only to `flow_id == "create-framework"`.
      `"from_template" | "scratch" | "extend_existing" | "merge"` when
      the message clearly signals which fork of
      `:choose_starting_point` the user wants, or `""` otherwise.
      Always `""` for `flow_id == "edit-framework"` (edit doesn't go
      through the choose-starting-point fork). Validated against a
      string whitelist server-side (Iron Law #10 — no `String.to_atom`).
    * `library_hints` — list of name fragments of existing libraries.
      A singleton list when the user references one existing library
      (`flow_id == "edit-framework"`, or `flow_id == "create-framework"`
      with `starting_point == "extend_existing"`); a two-element list
      when `starting_point == "merge"`. The LV resolves each hint
      against the org's libraries (case-insensitive substring,
      unique-match-or-drop) and appends `library_id` (singleton) or
      `library_id_a` + `library_id_b` (pair) to the wizard query
      string. Empty list when the message doesn't reference any
      existing framework.

  ## Test seam

  Override the module at the call site:

      Application.put_env(:rho_frameworks, :match_flow_intent_mod, FakeMatcher)

  where `FakeMatcher.call/2` returns `{:ok, %{...}} | {:error, term}`.
  Same shape as the `:choose_next_flow_edge_mod` seam in the Hybrid
  policy.
  """
  use RhoBaml.Function,
    client: "OpenRouterHaiku",
    params: [message: :string, known_flows: :string]

  @schema Zoi.struct(__MODULE__, %{
            flow_id: Zoi.string(description: "Matched flow id, or \"unknown\"."),
            confidence: Zoi.float(description: "0.0 (no match) to 1.0 (clearly this flow)."),
            reasoning: Zoi.string(description: "One-sentence justification."),
            name:
              Zoi.string(description: "Framework name. Empty string when flow_id is \"unknown\"."),
            description:
              Zoi.string(
                description:
                  "One-sentence framework description. Empty string when flow_id is \"unknown\"."
              ),
            domain:
              Zoi.string(
                description:
                  "Industry/domain noun phrase. Empty string when flow_id is \"unknown\"."
              ),
            target_roles:
              Zoi.string(
                description:
                  "Title-case singular role names. Empty string when flow_id is \"unknown\"."
              ),
            starting_point:
              Zoi.string(
                description:
                  "One of \"from_template\", \"scratch\", \"extend_existing\", \"merge\", or \"\" when no signal."
              ),
            library_hints:
              Zoi.array(Zoi.string(),
                description:
                  "Name fragments of existing libraries: singleton for \"extend_existing\", two for \"merge\", empty list otherwise."
              )
          })

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @type t :: unquote(Zoi.type_spec(@schema))

  @prompt ~S"""
  {{ _.role("system") }}
  You are an intent classifier for a skill-framework builder. The user
  types a free-form sentence describing what they want to build, and you
  match it to one of the known flows and extract any concrete fields they
  named.

  Rules:
  - Return flow_id as one of the known flow ids verbatim, or the literal
    string "unknown" if no flow fits.
  - confidence must reflect how clearly the message names the flow's
    purpose. 0.9+ = unambiguous, 0.5–0.9 = plausible, < 0.5 = guessing.
  - Choosing between create-framework and edit-framework:
      * "edit-framework" — the user wants to change an existing
        framework (verbs: edit, update, modify, fix, tweak, rename,
        adjust). The message names the existing framework. Set
        library_hints to a singleton with the name fragment.
      * "create-framework" — the user wants to build something new,
        even when seeded from an existing framework (verbs: create,
        build, design, make, generate, extend, fork, merge).
  - When flow_id is "create-framework", propose a sensible value for
    ALL of name, description, domain, target_roles. The user is filling
    an intake form they can edit before submitting — defaults beat
    blanks. When flow_id is "edit-framework" or "unknown", leave those
    four fields empty (edit doesn't go through intake).
  - name: 1–4 word concise title (e.g. "Backend Engineering").
  - description: one short sentence (e.g. "Skills for backend engineers").
  - domain: a single short noun phrase (e.g. "Software", "Healthcare").
  - target_roles: comma-separated, title-case, singular role names
    (e.g. "Backend Engineer, Tech Lead", NOT "backend engineers").
  - starting_point applies ONLY to flow_id == "create-framework". For
    "edit-framework" and "unknown", set starting_point to "".
    For "create-framework", pick exactly one of:
      * "extend_existing" — the user explicitly references one existing
        framework they want to build on (e.g. "like our SFIA framework
        but for PMs", "extend our backend skills"). Set library_hints
        to a singleton with the name fragment they used (e.g. ["SFIA"]).
      * "merge" — the user wants to combine TWO existing frameworks
        into a new one (e.g. "merge our SFIA and DAMA frameworks",
        "combine our backend and platform skills into one"). Set
        library_hints to BOTH fragments in the order they appeared
        (e.g. ["SFIA", "DAMA"]).
      * "from_template" — the user wants to seed from a similar role
        (e.g. "based on backend engineer skills", "starting from a
        senior PM template").
      * "scratch" — the user signals a brand-new niche with no seed
        (e.g. "for a niche I haven't built before", "from nothing").
      * "" — the message is too vague to commit to a fork. Prefer ""
        over guessing; the wizard will ask the user.
  - library_hints:
      * For flow_id="edit-framework": one element naming the framework
        the user wants to edit (e.g. ["SFIA"]).
      * For flow_id="create-framework" with starting_point="extend_existing":
        one element naming the source library (e.g. ["SFIA"]).
      * For flow_id="create-framework" with starting_point="merge":
        two elements naming both libraries (e.g. ["SFIA", "DAMA"]).
      * Otherwise: empty list [].
  - Reasoning must be one short sentence in plain English.

  Examples:
    "create a framework for backend engineers"
      → flow_id="create-framework", starting_point="from_template", library_hints=[]
    "like our SFIA framework but for PMs"
      → flow_id="create-framework", starting_point="extend_existing", library_hints=["SFIA"]
    "merge our SFIA and DAMA frameworks"
      → flow_id="create-framework", starting_point="merge", library_hints=["SFIA", "DAMA"]
    "combine our backend and platform skills into one"
      → flow_id="create-framework", starting_point="merge", library_hints=["backend", "platform"]
    "based on backend engineer skills"
      → flow_id="create-framework", starting_point="from_template", library_hints=[]
    "for a brand-new niche I haven't built before"
      → flow_id="create-framework", starting_point="scratch", library_hints=[]
    "build me a framework"
      → flow_id="create-framework", starting_point="", library_hints=[]
    "edit our SFIA framework"
      → flow_id="edit-framework", starting_point="", library_hints=["SFIA"]
    "update the backend skills framework — fix the senior level descriptions"
      → flow_id="edit-framework", starting_point="", library_hints=["backend skills"]
    "rename a few skills in our DAMA framework"
      → flow_id="edit-framework", starting_point="", library_hints=["DAMA"]

  {{ _.role("user") }}
  Known flows (id — what it does):
  {{known_flows}}

  Message: {{message}}

  {{ ctx.output_format }}
  """
end
