# Future Enhancement: Multi-Agent Communication Topology

## Problem

Currently, `send_message` in the `MultiAgent` mount is an open channel — any agent can message any other agent in the same session. `list_agents` exposes all agents to all agents. There is no access control.

This works for simple peer-to-peer scenarios (3 evaluators debating) but breaks down when:

- **Authority hierarchies exist** — evaluators messaging a chairman agent wastes LLM calls and creates confusion about who sets policy.
- **Sessions grow large** — with 10+ agents, open messaging becomes noise. Agents spend turns responding to irrelevant messages instead of doing their work.
- **Trust levels differ** — a subagent shouldn't be able to inject content into the primary (human-facing) agent's conversation by sending it a message.
- **Coordination patterns have structure** — hub-and-spoke, pipeline, or tree topologies where communication should follow defined paths.

## Observed in Practice

In the Hiring Committee Observatory demo:
- 3 evaluator agents + 1 chairman agent in a session
- Evaluators would `send_message` to the chairman asking procedural questions
- Chairman had to waste LLM calls refusing ("that's the coordinator's job, not mine")
- Chairman's system prompt enforcement works ~95% of the time, but it's not guaranteed
- Prompt-level constraints are fragile — a strongly-worded evaluator can override them

## Two Orthogonal Concerns

### 1. Visibility — Who can an agent discover?

`list_agents` currently returns ALL agents in the session. Options:

| Strategy | Description | Use Case |
|----------|-------------|----------|
| **Open** (current) | All agents visible | Small peer groups |
| **Group-scoped** | Only agents in same group | Evaluators see evaluators, not chairman |
| **Depth-scoped** | Only agents at same depth level | Subagents don't see the primary agent |
| **Allow-list** | Agent sees only explicitly permitted agents | Strict control for sensitive sessions |

### 2. Reachability — Who can an agent message?

`send_message` currently accepts any agent_id. Options:

| Strategy | Description | Use Case |
|----------|-------------|----------|
| **Open** (current) | Message anyone | Brainstorming, flat teams |
| **Peer-only** | Same group/role only | Evaluators debate, can't message chairman |
| **Parent-child only** | Can only message spawner or spawned agents | Strict delegation trees |
| **Directional** | Some links are one-way (chairman → evaluator, not reverse) | Authority hierarchies |
| **Allow-list** | Explicit per-agent target list | Maximum control |

## Possible Implementation Approaches

### A. Mount-Level Configuration (Recommended)

Define communication policy when configuring the `MultiAgent` mount:

```elixir
# In .rho.exs or spawn_evaluators:
mounts: [{:multi_agent, communication: :group_peers}]

# Or more explicitly:
mounts: [{:multi_agent,
  can_message: [:technical_evaluator, :culture_evaluator, :compensation_evaluator],
  visible_to: [:technical_evaluator, :culture_evaluator, :compensation_evaluator, :chairman]
}]
```

The `MultiAgent` mount would filter `list_agents` results and validate `send_message` targets at tool execution time.

Pros: clean, declarative, enforced at the tool level (not prompt level)
Cons: mount options become more complex, need to handle the "denied" case gracefully for the LLM

### B. Session-Level Topology

Define the communication graph at the session/simulation level:

```elixir
# In Simulation coordinator:
topology = %{
  evaluators: [:technical_evaluator, :culture_evaluator, :compensation_evaluator],
  chairman: [:chairman],
  rules: [
    {:evaluators, :can_message, :evaluators},
    {:chairman, :can_message, :evaluators},
    {:chairman, :can_message, :chairman}
    # evaluators CANNOT message chairman (not listed)
  ]
}
```

Pros: centralized, easy to reason about
Cons: requires a new concept (topology) in the framework, more complex to implement

### C. Agent-Level Permissions

Each agent carries its own communication permissions:

```elixir
# When spawning:
Supervisor.start_worker(
  agent_id: agent_id,
  can_message: ["agent_123", "agent_456"],  # explicit targets
  # or
  message_scope: :depth_peers  # shorthand
)
```

Pros: flexible, per-agent control
Cons: scattered across spawn sites, hard to see the full picture

## Recommendation

**Start with Approach A (mount-level)** for the common case. The `MultiAgent` mount already controls which tools are available — extending it with `can_message` and `visible_agents` options is a natural fit.

The `send_message` tool's `execute` function already has access to the session_id and agent registry. Adding a target validation check is straightforward:

```elixir
# In send_message execute:
if allowed_targets && target_id not in allowed_targets do
  {:error, "You cannot message #{target}. You can only message: #{allowed_names}"}
end
```

The error message tells the LLM who it CAN message, so it can self-correct.

## Use Cases Beyond Hiring

| Scenario | Topology |
|----------|----------|
| **Hiring committee** | Evaluators peer-to-peer. Chairman → evaluators (one-way). |
| **Code review pipeline** | Author → reviewer → author (bidirectional pair). Other reviewers are peers. |
| **Research team** | Researchers peer-to-peer. Coordinator hub. Researchers can't message coordinator directly — they `finish` and coordinator collects. |
| **Customer support** | Triage agent → specialist agents (one-way delegation). Specialists can escalate back to triage but not message each other. |
| **Debate with judge** | Debaters peer-to-peer. Judge observes but doesn't participate until asked. Debaters can't message judge. |

## Priority

Low-medium. Prompt-level enforcement works for the current demo. This becomes important when:
- Sessions regularly have 5+ agents
- Multiple demos/use-cases need different topologies
- Users are building production multi-agent systems (not just demos)

## Related

- `lib/rho/mounts/multi_agent.ex` — current send_message/list_agents implementation
- `docs/multi-agent-plan.md` — original multi-agent architecture plan
- `.rho.exs` — agent profiles with mount configuration
