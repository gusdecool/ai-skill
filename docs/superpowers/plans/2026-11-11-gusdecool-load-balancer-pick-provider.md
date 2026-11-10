# Load balancer: a script picks the provider

Spec: `docs/superpowers/specs/2026-11-11-gusdecool-load-balancer-pick-provider-design.md`

### Task 1: Add the script and its test (judgment)
- [x] Write `skills/gusdecool-load-balancer/scripts/pick-provider`
- [x] Write `tests/gusdecool-load-balancer.test.sh` with the BM-55 numbers
### Task 2: Delegate gusdecool-board-worker's scoring (judgment)
- [x] Make `gusdecool-board-worker/scripts/pick-provider` call the new script; existing gusdecool-board-worker
  tests stay green
### Task 3: Update the SKILL.md files (mechanical)
- [x] gusdecool-load-balancer SKILL.md: run the script, paste the table, keep cutoff, tie-break and parallel rules
- [x] gusdecool-board-worker SKILL.md step 4: the `Dispatch:` comment includes the score table
### Task 4: Verify and open the PR (mechanical)
- [x] Run all tests and `tests/check-structure.sh`
- [x] Open the PR (do not merge)
