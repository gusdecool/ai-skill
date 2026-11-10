# Board ticket dependencies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The board dispatcher builds blocking tickets first and reminds the owner when a blocker is not queued.

**Architecture:** Jira `Blocks` links are the source of truth. `board-ticket-cli` creates and lists them,
`board-pick-next` walks them before taking a ticket, `gusdecool-board-issue` asks for them when a ticket is written.

**Tech Stack:** bash, jq, the curl stub in `tests/stubs`.

**Spec:** `docs/superpowers/specs/2026-11-10-board-dependencies-design.md`

## Global Constraints

- Lines at most 120 characters. Every function has a doc comment. Handle errors explicitly.
- Tests never call Jira: use the curl stub. Based on branch `refactor/board-ticket-cli` (the script is named
  `board-ticket-cli`).
- Finished means status QA or Done. Only link type `Blocks` counts.

## Review Focus

- A blocker in a repo of a not-allowed owner is never picked: the dependent is parked.
- A ticket with a blocker that was parked earlier in the same run is parked once, with that blocker named.
- A two-ticket cycle parks both once, not in a loop.
- A `Relates` link and a `Blocks` link where the ticket is the blocker (outward) are ignored.
- `--dry-run` never mutates.

---

### Task 1: board-ticket-cli link and blockers (judgment)

**Files:**
- Modify: `skills/gusdecool-board-worker/scripts/board-ticket-cli`
- Test: `tests/board-ticket-cli.test.sh`

**Interfaces:**
- Produces: `board-ticket-cli link <key> blocked-by <blocker-key>` (exit 0, prints nothing),
  `board-ticket-cli blockers <key>` (prints `[{"key","status","finished"}]`).

- [x] **Step 1: Write failing tests**: `blockers` lists only inward `Blocks` links with `finished` true for QA and
  Done; `link` posts `{"type":{"name":"Blocks"},"outwardIssue":{"key":<blocker>},"inwardIssue":{"key":<key>}}` to
  `/rest/api/2/issueLink`; `link` twice posts once; `link` to itself exits 2 with no call.
- [x] **Step 2: Run them, see them fail** (`bash tests/board-ticket-cli.test.sh`).
- [x] **Step 3: Implement** `cmd_blockers` and `cmd_link` and add both to the usage text and the dispatch.
- [x] **Step 4: Run the tests, see them pass.**
- [x] **Step 5: Commit.**

### Task 2: board-pick-next honors blockers (judgment)

**Files:**
- Modify: `skills/gusdecool-board-worker/scripts/board-pick-next`
- Test: `tests/gusdecool-board-worker.test.sh` (section "Pick next")

**Interfaces:**
- Consumes: the Todo search now also returns `issuelinks`.

- [x] **Step 1: Write failing tests** for each rule in the spec: blocker in Todo is picked first (and a chain of
  two); blocker In progress skips quietly; blocker in Backlog or HITL parks with a comment naming it; blocker QA or
  Done is no blocker; cycle parks both; blocker of a not-allowed owner parks the dependent; a `Relates` link is
  ignored; a blocker parked earlier in the run parks the dependent once; `--dry-run` changes nothing.
- [x] **Step 2: Run them, see them fail.**
- [x] **Step 3: Implement** a `resolve` walk in `board-pick-next` and use it in the candidate loop.
- [x] **Step 4: Run all board tests, see them pass.**
- [x] **Step 5: Commit.**

### Task 3: skill text (mechanical)

**Files:**
- Modify: `skills/gusdecool-board-issue/SKILL.md`, `skills/gusdecool-board-worker/SKILL.md`,
  `skills/gusdecool-board-worker/scripts/board-pick-next`
  header comment

- [x] **Step 1: gusdecool-board-issue**: in step 2 ask which tickets block the new one (options from the open
  tickets of the
  same epic or repo, none as the default); in step 7 run `board-ticket-cli link <key> blocked-by <blocker>` for each;
  in step 9 report them. Add the dependency note to the draft template under Constraints.
- [x] **Step 2: gusdecool-board-worker**: describe the dispatcher rule in one short paragraph (workers still use only
  the four
  subcommands).
- [x] **Step 3: Run all tests and `bash tests/check-structure.sh`; check no line exceeds 120 characters.**
- [x] **Step 4: Commit, push, open the PR (base `refactor/board-ticket-cli`), watch CI.**
