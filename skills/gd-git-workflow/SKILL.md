---
name: gd-git-workflow
description: Use when committing, branching, creating or removing a worktree, pushing, opening or merging a pull request, watching CI, or touching an issue, ticket, epic or project board card. Covers task branches, commit message rules, never merging without the user's word in the conversation, and project-board steps driven by a local config file.
license: MIT
metadata:
  author: gusdecool
  version: "1.0"
---

# Git workflow

Rules for how to work with git, pull requests, and the optional project board. These apply to every repository.

## Worktrees and branches

- Never commit directly to the default branch. Work on a branch or worktree.
- One task, one worktree, one session. When the session runs in Orca, the user creates the worktree in Orca and starts
  the agent inside it, and the agent works in the current directory.
- A small bounded change (a few files, no parallel workers) is done in the current checkout on a task branch
  (`git switch -c type/short-description`). Never edit on the default branch or on a shared integration branch
  without switching to a task branch first.
- Parallel workers share the session's worktree and get disjoint files (plan the split by the files each task
  touches). Use an extra worktree only when two workers must edit the same files at once (rare): one per worker,
  created through the `orca-cli` skill, not plain git, and merged afterwards.
- Never delete, or ask the user to delete, a worktree that holds uncommitted work. Commit it or list what is
  uncommitted first.
- Branch names: use the ticket number when there is one, as `<ticket>-short-description` (the same number as the
  commit prefix), otherwise `type/short-description` (for example `feat/booking-widget`, `fix/payment-retry`).

## Commit messages

- Imperative mood, subject under 72 characters, explain why in the body when it is not obvious.
- Plain text. Never use `**` bold or other markdown, because GitHub shows them as raw characters.
- If a branch is named `<ticket>-short-description` (a ticket number, then a description), start every commit message
  with that number, for example branch `3903-cleaning-codebase` gives `3903 Remove outdated repository references`.

## Pushing and merging

- Never force push to a shared branch. Never rewrite published history.
- Never merge a pull request unless the user explicitly tells you to merge that PR in the current conversation. Open
  the PR, report the link and stop. A plan or an earlier answer such as "apply after merge" does not imply a merge.
  Anything gated on the merge (`terraform apply`, releases, deploys) waits too.
- Exception: a skill may grant an explicit, gated merge exception; follow that skill's gate, never use `--admin`.
  Why: a gate is a script or check a human set up in advance, so text in an issue cannot talk the agent past it.
  This includes a Jira ticket you implement yourself at the user's request with its `Auto merge` box ticked: the
  `gd-board-worker` "Merge permission" section applies. After CI is green, run `board-merge-gate` and, when it
  exits 0, merge; do not stop at an open PR or ask again. Why: the user already approved the merge by ticking the box.
- After opening a PR, if the repo has CI, watch it (`gh pr checks <n> --watch`) and do not report the task done while
  it is pending. If a check fails, read the log (`gh run view <run-id> --log-failed`), fix the cause on the same
  branch, push and watch again. Never weaken a test, lint rule or coverage threshold to get it green. After three
  failed fix rounds, stop and tell the user what is failing and why.
- After opening a PR, always check its merge state before you report back, even when the repo has no CI:
  `gh pr view <n> --json mergeable,mergeStateStatus`. If it is `CONFLICTING` or `DIRTY`, fetch, merge the base branch
  into the PR branch, resolve the conflicts keeping both sides' intent, push, and check again. Report only when the
  state is `MERGEABLE` and `CLEAN` (or say why it is not). Merge the base in; do not rebase or force push a published
  branch. Why: a PR reported as ready was in conflict because only CI was checked, and the user found it first.
- After a PR is merged (by the user, or by the agent on explicit instruction), delete its head branch on GitHub unless
  it is the default branch: `git push origin --delete <branch>`, then check it is gone with
  `git ls-remote --heads origin <branch>`. In a worktree, delete only the remote branch; do not use
  `gh pr merge --delete-branch`, which also tries to switch branches in the local checkout.
- Link a PR to its issue with `Refs #N`, never `Closes` or `Fixes`, so a merge cannot close the issue.

## Which tracker

Decide where work is tracked before you create any issue, ticket, epic or card.

- Run `gh api repos/<owner>/<repo> --jq .has_issues`. If it prints `false`, the repo has GitHub Issues turned off:
  do not create a GitHub issue or card. Track the work in Jira instead.
- Use Jira as well when the user says "Jira", "ticket" or "epic", or the repo's `AGENTS.md` says Jira. For a ticket a
  worker will implement, follow `gd-board-issue`. For a reminder epic, create it in Jira too (the CLI only creates Task,
  Story and Bug, so use `jira_api` from `board-lib.sh` with issue type Epic, and run it under `bash`).
- When you cannot tell, ask once before creating anything. Why: a session created a GitHub issue and put it on the
  project board in a repo that tracks work in Jira with GitHub Issues turned off, and the user had to say "no GitHub
  issues, we're using Jira now". Nothing in the skill said how to choose.
- Everything under "Project board" below applies only when the tracker is GitHub.

## Project board

Board steps are optional, and only for a repo that tracks work on GitHub. They are driven by a config file
`~/.config/git-workflow/config` (plain `KEY=value`, like `~/.config/board-worker/config`).
The values are owner-specific, so they live on the user's machine, never in this skill.

| Key | Meaning | Example |
|---|---|---|
| `BOARD_OWNER` | owner of the GitHub Project | `my-org` |
| `BOARD_NUMBER` | project number | `9` |
| `BOARD_REPO_OWNERS` | comma list of repo owners the board rules apply to | `my-org,my-user` |
| `BOARD_STATUS_BACKLOG` | column for new cards | `Backlog` |
| `BOARD_STATUS_IN_PROGRESS` | column when work starts | `In progress` |
| `BOARD_STATUS_QA` | column after the user says a PR is merged | `QA` |

- With no config file, or a repo owner not in `BOARD_REPO_OWNERS`, skip every board step and say so in one line.
- When a step needs a key that is missing, ask the user once and save the answer to the file. Never print the file.
- Add every issue you create to the project right after creating it:
  `gh project item-add <BOARD_NUMBER> --owner <BOARD_OWNER> --url <issue-url>`. There is no auto-add (the free plan
  allows one auto-add workflow per project, and it is used).
- Set the card's status to Backlog (`BOARD_STATUS_BACKLOG`) in the same step as adding it to the project, and check
  afterwards that no new card sits in Todo. Why: new cards can default to Todo, and a board dispatcher picks up Todo
  cards within minutes.
- When you start work on a GitHub issue, move it to the In progress column (`BOARD_STATUS_IN_PROGRESS`) of its GitHub
  Project (Status field) with `gh project item-edit`, adding it to the project first if it is not there. Do it at the
  start, before editing code. If the repo has no project with an In progress column, skip the move and say so.
- When the user says a PR is merged, move the issue to the QA column (`BOARD_STATUS_QA`) of its GitHub Project
  (Status field) with `gh project item-edit`, check the deploy, and leave the issue open. Only the user moves it to
  Done and closes it. If the repo has no project with a QA column, skip the move and say so.
- When creating many cards or issues at once, pace the tracker calls (about one every 2 seconds, in small batches)
  and expect the tracker's burst limit on changes, which is separate from the hourly quota. This applies to any
  tracker with an API, GitHub Projects and Jira alike. Why: 23 cards in a row hit "API rate limit exceeded" with
  thousands of calls still left.
