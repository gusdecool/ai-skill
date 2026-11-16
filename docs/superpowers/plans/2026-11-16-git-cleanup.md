# git-cleanup plan

Spec: `docs/superpowers/specs/2026-11-16-git-cleanup-design.md`

### Task 1: script and tests
- [x] Write `skills/gd-git-workflow/scripts/git-cleanup`.
- [x] Write `tests/gd-git-workflow.test.sh` (merged, closed, open, no PR, dirty, extra commit, unpushed, main checkout,
      current worktree, dry run) and run it.
- [x] Add the test and shellcheck to `.github/workflows/ci.yml`.

### Task 2: skill rules
- [x] Add "Push and clean up" to `gd-git-workflow`.
- [x] Call the script from `gd-orchestrate-ticket` and `gd-load-balancer`.

### Task 3: ship
- [x] Open the PR, watch CI, check merge state.
- [x] After the user merges: `npx skills update -g`, then run `git-cleanup` in ai-skill and agent-standards.
- [x] agent-standards PR with the one-line rule.
