# gd-orchestrate-ticket: one Orca worktree orchestrates a ticket across repos

## Why

The owner has many repos in Orca. A ticket often touches one or more repos other than the one the session runs in.
Today the owner opens each repo by hand. The session in the orchestrator worktree (the `idea` repo) should do it:
read the ticket, start one worker per touched repo, and track them from its own worktree card.

## Decisions (from the owner, 2026-11-12)

- Workers report back with `orca orchestration worker-start`. The orchestrator ends its turn and Orca wakes it, so
  waiting costs no tokens. It never polls and never uses `check --wait`.
- The plan declares dependencies between repos: independent repos start together, dependent ones start after their
  upstream worker reports done.
- The orchestrator proposes the repos and the owner confirms once per ticket.
- The Jira ticket's components name the related repos.
- The skill lives in `ai-skill`, not in a project repo.
- Models follow `gusdecool-model-policy`. The skill names no model.

## Parts

1. `scripts/ticket-repos <component>...`: maps Jira component names to Orca repos.
   - Reads `orca repo list --json`; a component matches a repo `displayName`, case-insensitive.
   - Optional overrides in `~/.config/orchestrate-ticket/repos`, lines `component=repo-display-name`
     (env `ORCHESTRATE_TICKET_REPOS` replaces the path, for tests).
   - Prints a JSON array of `{component, repoId, path}`; `repoId` and `path` are `null` when unmatched.
   - Exit 0 when all matched, 3 when any is unmatched, 2 on usage errors.
2. `SKILL.md`: the steps the orchestrator follows (below).
3. A README row.

## Skill steps

1. Read the ticket with `board-ticket-cli view <KEY>`; take `components`.
2. Run `ticket-repos`. Show the repo list and ask the owner once: confirm, add or remove repos, or name the repo for
   an unmatched component.
3. Write `tickets/<KEY>/plan.md` in the orchestrator's repo: repos, one self-contained brief per repo, dependencies,
   and a status table. Commit it on the task branch.
4. Start every repo with no open dependency: `orca orchestration worker-start --worktree new-top-level --repo
   id:<repoId> --name <KEY>-<repo> --spec "<brief>"`, then link the new worktree under this one with
   `orca worktree set --worktree <id> --parent-worktree active` and its ticket URL as a reference. End the turn.
5. When Orca wakes the orchestrator: answer a worker `question` if the plan answers it, start newly unblocked repos,
   or steer a stopped worker with `orca orchestration send`. Update the status table.
6. When every worker has settled, comment on the Jira ticket with `board-ticket-cli comment` and report each repo's
   PR as a full URL with its outcome. Never merge.

## Worker brief contract

Each brief states: the repo and ticket, the change, files the worker may touch, the evidence of done (tests, lint),
"work on a task branch named `<KEY>-short-description`, open a PR, never merge", "update the worktree comment at each
checkpoint", and, for a dependent repo, the upstream branch or PR to build on.

## Non-goals

No new Jira client, no provider ranking (see `gusdecool-load-balancer`), no merging, no repo map file in the project
repo. The unverified part is whether `worker-start` accepts a parent flag; step 4 uses `worktree set` instead.
