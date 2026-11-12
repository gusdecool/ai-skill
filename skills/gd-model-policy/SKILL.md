---
name: gd-model-policy
description: Use when dispatching a subagent or worker, choosing a model for any phase, or setting reasoning effort. Picks the tier (Low, Mid, High, Ultra) for each phase of agent work from the user's models.md and keeps code generation on the cheapest tier that fits. Works in any agent.
license: MIT
metadata:
  author: gusdecool
  version: "1.0"
---

# Model policy

Spend reasoning on brainstorming, planning and review. Code generation from a written plan runs on a cheaper tier.
This overrides any skill text that says "most capable available model".

## Read the tier table

Rules here speak in tiers (Low, Mid, High, Ultra). Read `models.md` next to this skill for the tier table,
provider map and launch ids. This skill owns the tier rules; `models.md` owns the model names.
If `models.md` or its tier table is missing, ask the user which model to use per provider and stop until answered.
Why: lineups change every few weeks, so model names and launch ids need one source.

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
  Why: a failed fix does not authorize higher cost.
- Never use a model that is not in `models.md`, or one in a High or Ultra cell, unless the user says so in the
  conversation. If a model is unavailable (usage limits, errors), stop and tell the user instead of substituting a
  more expensive one. Why: availability must not silently change the approved cost.
- When writing a plan, tag each task "mechanical" or "judgment" so the implementer tier is decided up front. If unsure
  which tier a task is, ask in the one batched question round, not mid-run.
  Why: the implementer tier must be settled before dispatch.

## Dispatching subagents

Pin the tier's model explicitly with the tool's own mechanism. A dispatch with no model pin inherits the session's
model. Why: an expensive session must not silently make every subagent expensive.

- Claude Code: use an `sdd-*` agent whose definition pins the required tier, or set `model` to `haiku` (Low) or
  `sonnet` (Mid). Use `sdd-implementer` for Low, `sdd-implementer-sonnet` for Mid and `sdd-task-reviewer` for Mid
  reviews. `sdd-final-reviewer` requires High approval under the tier rules. Install the agents and hook with
  `scripts/install-claude-adapter`. The hook refuses an unpinned dispatch and asks for approval for other model
  values or a fork. Why: the hook prevents silent inheritance and gates expensive dispatches.
- Other tools: use their own subagent or model setting. Get the model from
  `scripts/resolve-model --provider <provider> --tier <tier>`; its `launchId` is the launch value. If the tool has no
  subagents, work inline when the session already runs the right tier. Why: each tool has its own way to pin a model.
- Workers: follow `gd-load-balancer` and run its `scripts/pick-provider --reserved <provider> --tier <tier>`.
  Pass its printed `model` to `--model`; never type an id by hand. Why: the resolver keeps worker ids in one place.

## Reasoning effort

Reasoning effort is medium for every tool, model and subagent (Claude `effort`, Codex `model_reasoning_effort`, Gemini
thinking level). Do not set it to high or max on your own: higher effort costs more and
makes some models use far more tokens on long tasks. Go higher only when the user asks, or after a medium-effort
attempt fails and the task is judgment-heavy; say so when you do. Never go below medium for planning or review.

## Subagents are for big work

A small bounded change (a few files, no plan document, approach agreed) is implemented inline, then gets one review at
the Mid tier; skip the review only for text-only or docs-only changes. Use the implementer and reviewer loop only for
a written plan with about four or more tasks.
