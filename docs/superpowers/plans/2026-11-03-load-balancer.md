# load-balancer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A skill that spreads implementation tasks across AI providers by quota, called from any agent.

**Architecture:** One `SKILL.md` (prose, no script) that reads tier rules from the user's `AGENTS.md`, detects the
orchestrator tool, and carries the selection rules plus an Orca adapter. The global `AGENTS.md` shrinks to a pointer.

**Tech Stack:** Markdown, Claude Code plugin manifests (already present).

**Spec:** `docs/superpowers/specs/2026-11-03-load-balancer-design.md`

## Global Constraints
- Lines at most 120 characters in README and docs (`tests/check-structure.sh`); SKILL.md is exempt but stay near it.
- Skill folder name equals frontmatter `name`: `load-balancer`.
- No tier table or model names copied into the skill; read them from `AGENTS.md`.

## Review Focus
- No orchestrator tool found: skill stops and tells the user.
- Caller is not Claude: the caller's provider gets the 80 and 75 cutoffs.
- `AGENTS.md` missing or has no tier table: skill asks the user instead of guessing models.
- Every provider over a cutoff: stop and report the earliest `resetsAt`.
- Quota unreadable for a provider: treat it as unavailable.

---

### Task 1: Write the skill and list it (judgment)

**Files:**
- Create: `skills/load-balancer/SKILL.md`
- Modify: `README.md` (skills table, line about install choice)

**Produces:** skill `load-balancer`, command `/gusdecool:load-balancer`.

- [x] **Step 1: Write `SKILL.md` with the sections in the spec; every Review Focus line has an explicit rule**
- [x] **Step 2: Add the README row for `/gusdecool:load-balancer`**
- [x] **Step 3: Run `bash tests/check-structure.sh`; expected `Structure checks passed`**
- [ ] **Step 4: Commit**

### Task 2: Trim the global AGENTS.md (judgment)

**Files:**
- Modify: `agent-standards/global/AGENTS.md` sections 10 and 11 (separate repo and PR; see its plan)

- [ ] **Step 1: Done in the agent-standards repo, plan `2026-11-03-load-balancer-pointer.md`**
