# Decision: making `rho_frameworks` non-LV-friendly without extracting it

**Date:** 2026-04-26 · **Status:** decided

## Context

The `apps/rho_web/` LiveView UI is a **demo to showcase capabilities**.
Production usefulness requires integrating with an existing Node.js
host application across some transport boundary (HTTP+SSE / WebSocket /
similar). At the same time, the LV demo continues to grow new features
and must keep working.

Two consumers, only one is currently being built. The right move is
**don't extract anything yet — but stop accumulating LV-only coupling.**

The existing seams are already at roughly the right level:

- `Rho.Session.run/2` — programmatic agent invocation
- `Rho.Events` — PubSub event bus, payloads are mostly primitive maps
- `Rho.Context` — already takes `user_id` / `organization_id` as opaque IDs
- `RhoFrameworks.Plugin` — only reads `organization_id` from context, no `Accounts.*` calls

Two warts blocked a future Node consumer. One was fixed today; the
other is deferred until a real consumer exists to design the contract
against.

## What changed today (2026-04-26)

`RhoWeb.Session.EffectDispatcher` → `Rho.Stdlib.EffectDispatcher`
(file moved to `apps/rho_stdlib/lib/rho/stdlib/effect_dispatcher.ex`,
test moved alongside, `SessionEffects` alias updated).

The dispatcher had zero Phoenix dependencies — it only used
`Rho.Stdlib.DataTable`, `Rho.Events`, `Rho.Effect.*`, and `:telemetry`.
The LiveView never called it directly; it subscribes to the events
the dispatcher publishes via `Rho.Events`.

After this move, a non-LV consumer can react to tool effects by
subscribing to `Rho.Events` topics (`data_table`, `workspace_open`)
without taking a Phoenix dependency. The LV demo is unaffected — the
event subscription path is unchanged; only the module name moved.

## What was deferred

**Accounts decoupling.** `RhoFrameworks.Library`,
`RhoFrameworks.Frameworks.RoleProfile`, and `RhoFrameworks.Frameworks.Lens`
have hard FKs to `RhoFrameworks.Accounts.User` /
`RhoFrameworks.Accounts.Organization`:

- `apps/rho_frameworks/lib/rho_frameworks/frameworks/library.ex:24`
- `apps/rho_frameworks/lib/rho_frameworks/frameworks/role_profile.ex:37-38`
- `apps/rho_frameworks/lib/rho_frameworks/frameworks/lens.ex:5`

For a Node host with its own user/org model, these FKs are wrong — Node
owns identity. Two realistic fixes:

1. **Opaque external IDs.** Drop the FKs; `library.organization_id`
   becomes a plain UUID string with no constraint. Cheap, loses
   referential integrity at the DB layer.
2. **Identity mirror.** Keep minimal `Identity` / `Tenant` tables in
   Elixir, sync from Node on first use. More machinery, FKs still
   work, can attach Elixir-side data to identities.

**Why deferred:**

- LV features in flight depend on the current shape — touching
  the FKs now creates merge pain.
- Without a real Node prototype to design against, we'd guess the
  contract wrong.

Revisit when there's a Node prototype that can validate the chosen
identity model end-to-end.

## Guidelines (don't make it worse)

To keep the architecture viable for both consumers without extracting
anything:

### G1 — New `Rho.Effect.*` types must be transport-agnostic

Effect payloads will eventually cross a wire to Node. They must
contain only:

- primitives (string, integer, boolean, float)
- atoms (will be stringified at the wire boundary)
- plain maps and lists composed of the above

No module references, no pids, no `Phoenix.LiveView.Socket` shapes,
no closures. If you find yourself wanting one, the right place is
the consumer (LV or Node), not the effect.

### G2 — New framework schemas should not add hard FKs to `RhoFrameworks.Accounts.*`

Existing FKs stay (see "What was deferred"). For any **new** identity
column on a framework schema:

- Use a plain `:string` (UUID) field — `field :owner_id, :string`
- Don't add `belongs_to(:owner, RhoFrameworks.Accounts.User)`

This keeps the new surface compatible with both an Accounts-based LV
demo and a Node-driven host where the IDs come from outside Elixir.

## Open questions for when a Node consumer materializes

1. **Transport** — HTTP+SSE for run + event stream? WebSocket for
   bidirectional? Phoenix Channel? Driven by the Node app's stack.
2. **Identity model** — opaque IDs (option 1) or identity mirror
   (option 2)?
3. **Auth between Node and Elixir** — shared secret, mTLS, JWT?
4. **Hex publication** — does `rho` / `rho_stdlib` / `rho_frameworks`
   eventually want to be hex packages, or stay umbrella-internal
   behind a deployed service?
