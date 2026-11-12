# gd-orchestrate-ticket Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** A skill that lets an Orca worktree orchestrate one Jira ticket across several repos.

**Architecture:** One mapping script (testable, no network) plus a SKILL.md that drives `board-ticket-cli` and the
`orca` CLI. Waiting is done by Orca waking the session.

**Tech Stack:** bash, jq, orca CLI.

**Spec:** `docs/superpowers/specs/2026-11-12-gd-orchestrate-ticket-design.md`

## Global Constraints

- Lines at most 120 characters; every function has a doc comment.
- Skill name `gd-orchestrate-ticket` equals its folder name; the description has no unquoted `: `.
- No model names in the skill.

## Review Focus

- Component with different case than the repo name matches.
- Unmatched component gives exit 3 and `null` fields, not a silent drop.
- Two repos with the same display name: report the component as unmatched (ambiguous), never pick one.
- No components on the ticket: the skill asks the owner which repos.
- Override file with a blank line or comment is ignored.

---

### Task 1: ticket-repos script

**Files:**
- Create: `skills/gd-orchestrate-ticket/scripts/ticket-repos`
- Modify: `tests/stubs/orca` (add `repo list` output from `$STUB_DIR/orca-repos`)
- Test: `tests/gd-orchestrate-ticket.test.sh`

**Interfaces:**
- Produces: `ticket-repos <component>...` printing `[{component, repoId, path}]`; exit 0 / 3 / 2.

- [x] **Step 1: Write the failing tests** (match, case-insensitive, unmatched exit 3, ambiguous, override, usage exit 2)
- [x] **Step 2: Run them and see them fail**: `bash tests/gd-orchestrate-ticket.test.sh`
- [x] **Step 3: Implement the script** with `repo_id_for`, then `main`
- [x] **Step 4: Run the tests and see them pass**
- [x] **Step 5: Commit** `Add ticket-repos script for gd-orchestrate-ticket`

### Task 2: skill text, README, CI

**Files:**
- Create: `skills/gd-orchestrate-ticket/SKILL.md`
- Modify: `README.md` (skills table and link), `.github/workflows/ci.yml` (run the new test)

- [x] **Step 1: Write SKILL.md** from the spec steps, with the worker brief contract
- [x] **Step 2: Add the README row and link; add the CI test step**
- [x] **Step 3: Run** `shellcheck skills/*/scripts/* tests/*.sh`, `bash tests/check-structure.sh`, the new test
- [x] **Step 4: Commit, push, open the PR**
