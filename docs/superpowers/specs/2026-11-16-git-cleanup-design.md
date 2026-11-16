# git-cleanup design

Goal: no stale branches or worktrees, and no question to the user about them (fewer human steps).

## Problem
- Squash merges leave local branches that `git branch --merged` cannot see. `ai-skill` had 19 local branches whose
  remote was already gone, and the main checkout sat on one of them.
- The skills that create worktrees (`gd-orchestrate-ticket`, `gd-load-balancer`) never pushed, cleaned up or asked.

## Behavior
`skills/gd-git-workflow/scripts/git-cleanup [--dry-run]` runs in a repo or any of its worktrees. After
`git fetch --prune`, for each local branch other than the `origin/HEAD` default:

| PR state (from `gh pr list --head`) | Condition | Action |
|---|---|---|
| merged | tip is inside the PR head, worktree clean | remove worktree, delete local and remote branch |
| closed, not merged | tip is on the remote, worktree clean | remove worktree, delete local branch, keep remote |
| open, none, unreadable | any | keep, print the reason |
| any | uncommitted changes, unpushed commits, or the current worktree | keep, print the reason |

A branch checked out in the main checkout makes it switch to the default branch first. Output is one line per branch.
Guess marked: closed PRs keep their remote branch (guess: the user would rather keep declined work than lose it).

## Wiring
- `gd-git-workflow`: push on commit, run the script at session end and after a merge or close, never ask.
- `gd-orchestrate-ticket`, `gd-load-balancer`: run it per worker repo when a PR is decided.
- agent-standards: one inline rule pointing at the script.
