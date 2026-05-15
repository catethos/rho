class MatchFlowIntentOutput {
  name string @description("Framework name. Empty string when flow_id is \"unknown\".")
  domain string @description("Industry/domain noun phrase. Empty string when flow_id is \"unknown\".")
  description string @description("One-sentence framework description. Empty string when flow_id is \"unknown\".")
  reasoning string @description("One-sentence justification.")
  confidence float @description("0.0 (no match) to 1.0 (clearly this flow).")
  target_roles string @description("Title-case singular role names. Empty string when flow_id is \"unknown\".")
  starting_point string @description("One of \"from_template\", \"scratch\", \"extend_existing\", \"merge\", or \"\" when no signal.")
  flow_id string @description("Matched flow id, or \"unknown\".")
  library_hints string[] @description("Name fragments of existing libraries: singleton for \"extend_existing\", two for \"merge\", empty list otherwise.")
}

function MatchFlowIntent(message: string, known_flows: string) -> MatchFlowIntentOutput {
  client OpenRouterHaiku
  prompt #"
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
  "#
}
