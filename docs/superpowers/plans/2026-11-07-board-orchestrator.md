# Board Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The board dispatcher's session orchestrates workers, watches them with a script, and takes over on another
provider when one hits a limit.

**Architecture:** A model-free `board-watch` script reports stuck or settled workers; the orchestrator (the existing
`BOARD-WORKER` session) reacts using the `load-balancer` takeover rules. `pick-provider --orchestrator` keeps the
orchestrator on Claude within its reserved cutoff.

**Tech Stack:** bash, jq, the `orca` CLI; tests in `tests/board-worker.test.sh`.

**Spec:** `docs/superpowers/specs/2026-11-07-board-orchestrator-design.md`

## Global Constraints

- Lines at most 120 characters. Every function has a doc comment. Scripts executable. No live API calls in tests.
- Cutoffs are the load-balancer's: 90 session / 95 weekly, reserved claude 80 / 75.
- `board-watch` exits 0 `settled`, 1 `stuck`, 2 cannot read.

## Review Focus

- A limit phrase more than 15 lines up the screen must not flag a worker (old output).
- A provider just under its cutoff (codex session 89) must not flag.
- Orca unreadable must exit 2, not report healthy.
- `--orchestrator` with claude over 80 session must exit 1 even when codex has quota.

---

### Task 1: board-watch script (judgment)

**Files:**
- Create: `skills/board-worker/scripts/orca-lib.sh`, `skills/board-worker/scripts/board-watch`
- Modify: `skills/board-worker/scripts/pick-provider` (use `orca_bin` from the lib)
- Test: `tests/board-worker.test.sh` (new "Board watch" section)

**Interfaces:**
- Produces: `orca_bin()` in `orca-lib.sh` (prints the orca binary: `ORCA_BIN`, else `orca` on PATH, else
  `ORCA_FALLBACK_BIN`); `board-watch <dispatch>:<provider> [...]` with env `WATCH_INTERVAL` (600), `SILENT_SECONDS`
  (600), `WATCH_MAX_POLLS` (unlimited; tests), `NOW_MS`, `LIMIT_PATTERN`; prints one JSON line, exits 0/1/2 (exit 3,
  event `none`, only when `WATCH_MAX_POLLS` runs out).

- [x] **Step 1: Write the failing tests** with a stub orca answering `orchestration worker-show`, `worker-read`
  and `account list`. Cases: stage settled exits 0 `settled`; `waitingOnHuman: true` exits 1 `waiting_on_human`;
  tail with "You've hit your usage limit ... try again at 3:13 PM" exits 1 `limit_text`; the same phrase 20 lines
  up does not flag; codex session 90 flags `quota_cutoff`, codex 89 does not; claude session 80 flags;
  identical tail on two polls with `SILENT_SECONDS=0` flags `silent`; failing `worker-show` exits 2.
- [x] **Step 2: Run them, expect FAIL** (`bash tests/board-worker.test.sh 2>&1 | grep '^FAIL'`).
- [x] **Step 3: Implement** `orca-lib.sh` and `board-watch`; per-worker silence state kept in a temp dir (macOS bash
  3 has no associative arrays); quota cutoff logic copied from `pick-provider`.
- [x] **Step 4: Point `pick-provider` at `orca_bin`** from the lib; its existing tests stay green.
- [x] **Step 5: Run the full test file, expect 0 FAIL;** run `bash tests/check-structure.sh`.
- [x] **Step 6: Commit** "Add board-watch: report stuck or settled workers without a model".

### Task 2: pick-provider --orchestrator and precheck (mechanical)

**Files:**
- Modify: `skills/board-worker/scripts/pick-provider`, `skills/board-worker/scripts/board-precheck`
- Test: `tests/board-worker.test.sh` ("Pick provider" section)

**Interfaces:**
- Consumes: `pick-provider` fixtures (`run_provider`, `tweak_accounts`).
- Produces: `pick-provider --orchestrator` prints the claude pick (exit 0) only when claude is eligible, else the
  error JSON and exit 1; `board-precheck` calls it with that flag and its failure line reads
  "no provider has quota left for the orchestrator (claude)".

- [x] **Step 1: Write failing tests:** claude under cutoff with codex higher scoring picks claude; claude session 80
  with codex free exits 1 with `error`; default call unchanged.
- [x] **Step 2: Run, expect FAIL.**
- [x] **Step 3: Implement** the flag by restricting `result` to claude before the eligibility check; update the
  precheck call and message.
- [x] **Step 4: Run the full test file, expect 0 FAIL.**
- [x] **Step 5: Commit** "Run the board orchestrator on claude within its reserved cutoff".

### Task 3: skill text and dispatcher prompt (mechanical)

**Files:**
- Modify: `skills/board-worker/SKILL.md`, `skills/load-balancer/SKILL.md`
- Modify (idea repo, separate PR): `docs/orca-kanban-automation.md`

- [ ] **Step 1: `board-worker/SKILL.md`:** add `board-watch` to the scripts list; step 4 orchestrates for two or more
  tasks (dispatch with `worker-start --worktree current`, run `board-watch` in the background, on `stuck` follow the
  load-balancer takeover, on `settled` check the work, release workers); one-task plans stay inline; heartbeat
  comment on each task finish, takeover and at least hourly; clock 180 minutes; only the orchestrator merges.
- [ ] **Step 2: `load-balancer/SKILL.md`:** the watch uses screen text and a human-prompt signal besides quota and
  silence; interval 10 minutes; never choose "switch model" on a provider prompt; the Orca adapter names `board-watch`.
- [ ] **Step 3: Run `bash tests/check-structure.sh` and the full test file, expect 0 FAIL.**
- [ ] **Step 4: Commit,** push, open the `ai-skill` PR (`Refs` the issue if one exists), watch CI.
- [ ] **Step 5: Idea repo:** branch, update `docs/orca-kanban-automation.md` (orchestrator flow, new prompt line),
  PR, watch CI.
- [ ] **Step 6: After the user merges:** `npx skills update -g`, then change the dispatcher prompt step 2 to
  `pick-provider --orchestrator` with `orca automations edit`.
