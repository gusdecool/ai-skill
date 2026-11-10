# gusdecool-board-issue skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox syntax. Tick a
> task's boxes in the same commit that finishes it.

**Goal:** A skill that turns a rough idea into a board-ready GitHub issue (final spec, optional `Auto merge: true`).

**Architecture:** A SKILL.md procedure for an interactive session; the only code change is that `board-check-ready`
can check a draft file, so the same readiness rules gate the draft before the issue exists.

**Tech Stack:** bash, jq, `gh`.

**Spec:** the user-approved design in the conversation of 2026-11-06 (gusdecool/idea issue 24); the issue template
is in `gusdecool/idea` `docs/orca-kanban-automation.md`. Stacked on `gusdecool/ai-skill` PR 7 (feat/gusdecool-board-worker).

## Global Constraints

- 120-column lines, doc comment above every function, `Refs #N` never `Closes`.
- The skill never writes `Auto merge: true` without an explicit yes from the user in the conversation, and never in a
  session whose prompt starts with `BOARD-WORKER`.
- The card is left in Backlog unless the user says to queue it (Todo starts work within 10 minutes).

---

### Task 1: Draft check in board-check-ready (mechanical)

**Files:** Modify `skills/gusdecool-board-worker/scripts/board-check-ready`, `tests/gusdecool-board-worker.test.sh`.

**Interfaces:** `board-check-ready --file <path>` reads a Markdown file instead of an issue; same output and exit codes
(2 when the file cannot be read).

- [x] **Step 1:** Add tests: a ready draft file passes; a draft missing Goal fails with `["Goal"]`; a missing file
  exits 2.
- [x] **Step 2:** Implement the `--file` form; keep `<issue-url>` unchanged.
- [x] **Step 3:** Run `bash tests/gusdecool-board-worker.test.sh` and `bash tests/check-structure.sh`; expect PASS.

### Task 2: gusdecool-board-issue skill and docs (mechanical)

**Files:** Create `skills/gusdecool-board-issue/SKILL.md`; Modify `README.md` (skills row).

- [x] **Step 1:** Write `SKILL.md`: when to use, one batched question round, the template, draft check, UAT and
  CI/CD/infra warnings, the `Auto merge` question, create and add to the project, Priority, the Backlog default.
- [x] **Step 2:** Add the README row and link; run `bash tests/check-structure.sh`; expect PASS.

### Task 3: PR (mechanical)

- [x] **Step 1:** Push `feat/gusdecool-board-issue`, open the PR with base `feat/gusdecool-board-worker` (`Refs gusdecool/idea#24`), watch
  CI. Waits for CI; the user merges PR 7 first, then retargets this PR to main.
