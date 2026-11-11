# Load balancer config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** Let a JSON config set per-provider cutoffs for `pick-provider`.

**Architecture:** `pick-provider` validates the config in bash+jq into a provider-to-percent map, and the jq `cutoff`
function consults that map before the defaults.

**Tech Stack:** bash, jq.

**Spec:** `docs/superpowers/specs/2026-11-11-load-balancer-config-design.md`

## Global Constraints

- Lines at most 120 characters; every function documented.
- Providers: `claude`, `codex`, `antigravity`, `opencodeGo`; cutoff is a fraction 0 to 1 applied to every window.

## Review Focus

- Cutoff 0 or 1 boundaries; floating fractions such as 0.07; main_orchestrator mismatch; missing vs explicit path.

---

### Task 1: Config parsing and cutoffs in pick-provider

**Files:**
- Modify: `skills/gusdecool-load-balancer/scripts/pick-provider`
- Test: `tests/gusdecool-load-balancer.test.sh`

- [x] **Step 1: Add failing tests** (main 0.5 skips claude at 50, worker 0.5 skips opencodeGo, unlisted unchanged,
  mismatch warns, `--orchestrator` uses main cutoff, missing default file is fine, bad files exit 2)
- [x] **Step 2: Run tests, see them fail**
- [x] **Step 3: Implement `--config`, validation and the cutoff map**
- [x] **Step 4: Run tests, see them pass**
- [x] **Step 5: Commit**

### Task 2: Document in SKILL.md

**Files:**
- Modify: `skills/gusdecool-load-balancer/SKILL.md`

- [x] **Step 1: Add a "Config" section and update cutoff text in "Choosing the provider" and the pause trigger**
- [x] **Step 2: Run `bash tests/check-structure.sh` and the load balancer test**
- [x] **Step 3: Commit, push, open the PR**
