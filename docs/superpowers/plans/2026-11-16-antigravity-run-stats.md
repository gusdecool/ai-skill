# Antigravity run stats plan

Spec: `docs/superpowers/specs/2026-11-16-antigravity-run-stats-design.md`

### Task 1: board-run-stats reads Antigravity transcripts
- [x] Add `--match`, the `antigravity` provider branch and the Gemini price row.

### Task 2: ticket-record-stats records the worker
- [x] Add `--antigravity-match`, skip a run already recorded, fail when no transcript matches.

### Task 3: Tests
- [x] Fake transcripts in `tests/gd-board-worker.test.sh`; stub case in `tests/gd-orchestrate-ticket.test.sh`.

### Task 4: Skill text
- [x] Replace "Gemini ... cannot be read" in the three places that say it.
