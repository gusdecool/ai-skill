---
name: gusdecool-model-policy
description: Use when dispatching a subagent or worker, choosing a model for any phase, or setting reasoning effort. Picks the tier (Low, Mid, High, Ultra) for each phase of agent work from the user's models.md and keeps code generation on the cheapest tier that fits. Works in any agent.
---

# Model policy

Spend reasoning on brainstorming, planning and review. Code generation from a written plan runs on a cheaper tier.
This overrides any skill text that says "most capable available model".

## Read the tier table

Rules here speak in tiers (Low, Mid, High, Ultra). The tier table and model names live in the user's `models.md`,
the file their global `AGENTS.md` names; read them from there, never from this skill. This skill holds no model names.
If there is no `models.md` or tier table, ask the user which model to use per provider and stop until answered.
Why: lineups change every few weeks, so only that file is updated, not the rules.

## Phase tiers

| Phase | Tier |
|---|---|
| Brainstorming and planning (the main session) | Mid |
| Implementer, mechanical task (pure functions, wiring, small components, docs, the plan gives the code) | Low |
| Implementer, DB / concurrency / multi-file integration / environment-heavy task | Mid |
| Per-task review and scoped re-review | Mid |
| Final whole-branch review (and any security- or concurrency-heavy diff) | Mid |

## Tier rules

- Mid is the default tier. High and Ultra are forbidden unless the user says so in the conversation; Ultra also needs
  the cost stated first, and one approval does not carry over to later tasks. Why: they cost several times more.
- A provider with `none` in a tier cannot serve that tier; never substitute another tier silently. Why: a silent swap
  changes cost and quality without the user knowing.
- Escalate one step at a time. After a failed fix round on a Low implementer, use Mid for the next round. A Mid
  implementer that is still stuck is not escalated to High: stop and tell the user.
- Never use a model that is not in `models.md`, or one in a High or Ultra cell, unless the user says so in the
  conversation. If a model is unavailable (usage limits, errors), stop and tell the user instead of substituting a
  more expensive one.
- When writing a plan, tag each task "mechanical" or "judgment" so the implementer tier is decided up front. If unsure
  which tier a task is, ask in the one batched question round, not mid-run.

## Dispatching subagents

- Claude Code: dispatch the `sdd-*` agents (`~/.claude/agents/sdd-*.md`): `sdd-implementer` (Low),
  `sdd-implementer-sonnet` (Mid), `sdd-task-reviewer` (Mid, also for the final review). Leave the `model` parameter
  out so the model comes from the agent definition. Never dispatch `sdd-final-reviewer` (it runs a High tier model).
- Codex and Gemini (Antigravity): use that tool's own subagent or model setting for the same role, with the model from
  `models.md`. If the tool has no subagents, do the work inline when the session already runs the right tier.
- Worker dispatch, `--model` slugs, worker release and stuck-worker handling for an orchestrator tool such as Orca are
  in the `gusdecool-load-balancer` skill. Whatever dispatches a worker must pass the model from `models.md` explicitly, never
  inherit the default.

## Reasoning effort

Reasoning effort is medium for every tool, model and subagent (Claude `effort`, Codex `model_reasoning_effort`, Gemini
thinking level). Do not set it to high or max on your own: higher effort costs more and
makes some models use far more tokens on long tasks. Go higher only when the user asks, or after a medium-effort
attempt fails and the task is judgment-heavy; say so when you do. Never go below medium for planning or review.

## Subagents are for big work

A small bounded change (a few files, no plan document, approach agreed) is implemented inline, then gets one review at
the Mid tier; skip the review only for text-only or docs-only changes. Use the implementer and reviewer loop only for
a written plan with about four or more tasks.
