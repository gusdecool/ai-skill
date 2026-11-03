# load-balancer skill design

## Goal
Move the provider load balancing logic out of the always-loaded global `AGENTS.md` into an on-demand skill, so
sessions that never dispatch workers do not pay about 1.5k tokens each. Invoked as `/gusdecool:load-balancer`.

## Decisions (agreed with the user)
- Orchestrator agnostic: whichever agent invokes the skill (Claude, Codex, Antigravity, others) is the orchestrator.
  Its own provider is the reserved one: it gets the lower cutoffs (80 session, 75 weekly) and keeps planning,
  brainstorming and reviews. Other providers use 90 and 95.
- Model tiers are not in the skill. The skill reads the user's `AGENTS.md` (tier table, model names, "never top
  tier", medium effort). Tiers apply with or without load balancing.
- Orchestrator tool is detected, not assumed. Orca is the only adapter with commands today. The skill states a
  tool-neutral contract, so another tool (opencode and so on) is added as an adapter once its commands are verified.
- No orchestrator tool found: stop and tell the user. Never pick a provider blind.

## Skill contents
1. Preconditions: read tier rules from `AGENTS.md`; detect the orchestrator tool; stop if none.
2. Tool contract: read quotas, launch a worker with provider, model and worktree, read output, stop, release.
3. Selection: cutoffs, urgency formula, tie-break, parallel spread, user pin, worked example.
4. Dispatch: pass the plan file, `--model` explicit, medium effort.
5. Watch: quota passing a cutoff or silent worker, then stop, keep the draft, hand over at the same tier.
6. Release settled workers; stop when every provider is over a cutoff and report the earliest reset.
7. Orca adapter: the exact commands (quota read, launch, worker-start, stop, release, model slug check).

## Global AGENTS.md change (agent-standards repo)
Section 11 becomes a pointer. Section 10 keeps tiers, rules and effort; the Orca-only bullets (model slugs,
`worker-start`, wake, release) move to the skill.
