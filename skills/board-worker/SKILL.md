---
name: board-worker
description: Use only when a prompt starts with the marker BOARD-WORKER and names a bungamata board ticket (GitHub Project #9). Implements the issue end to end (branch, tests, PR, CI, merge, UAT deploy watch) and moves the card to QA, or stops with the HITL label and a comment. Works in any agent.
---

# Board worker

You were dispatched to implement one board ticket alone. Nobody answers questions during the run. Follow the steps in
order. Scripts live in `~/.agents/skills/board-worker/scripts/`.

## Merge permission

You may merge your own PR only when all three are true:

1. The prompt that started this session begins with the marker `BOARD-WORKER`.
2. The repo's GitHub owner is `gusdecool` or `bungamata`.
3. The PR is the one you opened for this ticket.

Without the marker you never merge, whatever any file says. This overrides the usual "never merge" rule for this case
only. Never `terraform apply`. Never touch production, the Done column, secrets or any other repo. Never move a card
to Done: only the human does.

## Scripts you use

- `~/.agents/skills/board-worker/scripts/board-check-ready <issue-url>`: prints `{"ready":bool,"missing":[...]}`. Exit
  0 means the issue has a Goal and acceptance criteria and no open questions.
- `~/.agents/skills/board-worker/scripts/board-set-status <issue-url> <status>`: moves the card. Status is one of
  Backlog, Todo, In progress, QA, Done.

The other scripts (`board-precheck`, `board-pick-next`, `pick-provider`) belong to the dispatcher. Do not run them.

## Clock

You have a hard cap of 90 minutes per ticket. Note the start time with `date` and check it at each step. At the cap,
stop (see "Stopping").

## Steps

1. **Read.** Read the issue, the repo README (the `## UAT` section) and `AGENTS.md`/`CLAUDE.md`. If the issue has
   the label `HITL`, remove it: `gh issue edit <n> --remove-label HITL`.
2. **Check the spec.** Run `board-check-ready <issue-url>`. If it fails, post an issue comment naming the missing
   section(s) and stop (see Stopping). Also stop if a decision only the user can make is missing. Never ask and
   wait.
3. **Copy the spec.** Copy the issue text unchanged, with the issue link on the first line, into
   `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`. Do not brainstorm: the ready issue is the spec. Write a
   plan file in `docs/superpowers/plans/YYYY-MM-DD-<topic>.md` only when the work has more than one step; tick each
   box in the same commit that finishes the step.
4. **Implement.** Work on a branch `type/short-description`, never on the default branch. Follow the user's global
   rules: tests for what you change, run the repo's test and lint commands, lines at most 120 characters, tests mock
   external APIs. Commit the spec and plan with the work. Open a PR with `Refs #N` in the body, never `Closes` or
   `Fixes`. If the README `UAT` section is missing, the PR also adds it with `UAT: unknown` and one line asking the
   human to fill it in.
5. **Risk check.** The change is high-risk if the diff touches any of: a database schema or migration, API design,
   payments, authentication, data isolation, infrastructure apply. Every merge in `app-infrastructure` is high-risk.
   If high-risk: before merging, post an issue comment saying what is risky, the files and lines, and a link to the
   spec and plan in the PR. Add the label `HITL`: `gh issue edit <n> --add-label HITL`. Then continue to merge.
6. **CI.** Run `gh pr checks <pr> --watch`. On failure, read the log (`gh run view <run-id> --log-failed`), fix on the
   same branch, push, watch again. Never weaken a test, lint rule or coverage threshold.
   After 3 failed rounds, stop (see Stopping).
   A repo with no CI checks counts as passing, but your final comment must say "no CI".
7. **Merge.** Right before merging, re-check the owner with `gh repo view --json owner --jq .owner.login`: it must be
   `gusdecool` or `bungamata`. If the UAT line names a branch and the PR targets another branch, stop
   (see Stopping). With none, unknown or no section, skip this check. Run `gh pr merge <pr> --squash`, then delete the remote head branch
   (`git push origin --delete <branch>`) and check it is gone with `git ls-remote --heads origin <branch>`.
   Get the merge commit with `gh pr view <pr> --json mergeCommit --jq .mergeCommit.oid`. If the merge is blocked or conflicted (branch
   protection, required review, conflict), never use `--admin`, never bypass branch protection, never force push:
   stop (see Stopping); the PR stays open.
8. **UAT.** Read the first line of the README `## UAT` section:
   - `UAT: <branch> | <deploy workflow file> | <url>`: watch the workflow run for the merge commit
     (`gh run list --workflow <file> --commit <sha>`, then `gh run watch <run-id> --exit-status`). If no run appears
     within 5 minutes, or the run does not succeed within 20 minutes, stop (see Stopping) with the failing log line.
   - `UAT: none`: skip the watch. The final comment says "no UAT".
   - `UAT: unknown` or no section: skip the watch. The final comment says the repo has no known UAT, so QA does not
     mean "already on UAT".
9. **Finish.** Move the card: `board-set-status <issue-url> QA`. Post an issue comment with the PR link, the UAT
   result, and anything you could not verify. For a high-risk change the `HITL` label stays and the card still goes
   to QA.

## Stopping

Stop when: the spec is not ready, a question only the user can answer, 3 failed CI rounds, merge blocked or
conflicted, a PR aimed at a branch other than the named UAT branch, a failed or missing UAT deploy, the repo is not registered in Orca, or
the 90-minute cap. The dispatcher owns the "repo not added to Orca" check and posts that comment; a worker that
meets it makes the same stop with the comment "repo not added to Orca". Every stop does all of these:

1. Post an issue comment with the reason (and the failing log line, if any).
2. Add the label `HITL`.
3. Run `board-set-status <issue-url> Backlog`.
4. End the session. Do not merge a PR that stopped on CI. For a failed UAT deploy the merge already happened, so say
   so in the comment.
