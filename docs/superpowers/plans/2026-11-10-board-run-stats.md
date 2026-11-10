# Board run stats plan

Spec: `docs/superpowers/specs/2026-11-10-board-run-stats-design.md`

### Task 1: board-run-stats (mechanical)
- [x] Add `model-prices.tsv` and `scripts/board-run-stats` with a fixture log and tests
### Task 2: ticket CLI and setup (judgment)
- [x] Add `board-ticket-cli stats` (additive fields plus comment) with tests
- [x] Add `board-setup --stats-fields` with a test
### Task 3: skill text (mechanical)
- [x] Add the "Run stats" step and script docs to `SKILL.md`
### Task 4: follow-ups (not in this PR)
- [ ] Catch-all pass in `board-cleanup` for runs that crashed
- [ ] Codex and Gemini log readers
