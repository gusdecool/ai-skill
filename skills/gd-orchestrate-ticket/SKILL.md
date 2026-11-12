---
name: gd-orchestrate-ticket
description: Use when an Orca worktree session is given a Jira ticket to orchestrate, or the ticket touches other repos. Maps components to repos, starts a worker per repo in dependency order, tracks them, reports PRs. Never merges.
---

# Orchestrate a ticket across repos

This session is the orchestrator. It plans and tracks; the workers change code in their own repos. Needs the `orca`
CLI (load `orca-cli` and `orchestration` for command details), `board-ticket-cli` from `gusdecool-board-worker`, and
`jq`. Choose models per `gusdecool-model-policy`; name no model here.

## Steps

1. **Read the ticket.** `board-ticket-cli view <KEY>` gives `components`, `description`, `summary`. With no
   components, ask the owner which repos are touched.
2. **Map components to repos.** `scripts/ticket-repos <component>...` (next to this file) prints
   `{component, repoId, path}` per component; exit 3 means some are `null` (no match or two repos share the name).
   Overrides live in `~/.config/orchestrate-ticket/repos` as `component=repo-display-name` lines.
3. **Confirm once.** Show the repo list and the dependency order you propose (for example API before client). Ask the
   owner one question: confirm, add or remove repos, or name the repo for an unmatched component. Options, your
   recommendation first, tradeoff per option. After the answer, do not ask again.
4. **Write the plan.** `tickets/<KEY>/plan.md` in this repo: repos, one self-contained brief per repo, dependencies,
   and a status table (repo, worker, PR URL, state). Commit it on this worktree's task branch. Why: a new session
   resumes from the file, not from chat.
5. **Start the workers with no open dependency.** For each:
   `orca orchestration worker-start --worktree new-top-level --repo id:<repoId> --name <KEY>-<repo> --spec "<brief>"`.
   Then link it under this worktree: `orca worktree set --worktree <its id> --parent-worktree active`. Take the id
   from the receipt, or from `orca worktree list --repo id:<repoId> --json` by name. Then **end your turn**.
6. **When Orca wakes you.** Update the status table. Answer a worker `question` only if the plan answers it, else ask
   the owner. Start repos whose upstream worker reported `worker_done`, telling them the upstream branch or PR to
   build on. Steer a stopped worker with `orca orchestration send --to dispatch:<id>`. End your turn again.
7. **Finish.** When every worker has settled, comment on the ticket with `board-ticket-cli comment <KEY> "<text>"` and
   report each repo's PR as a full URL with outcome and open blockers. Do not merge anything.

Never poll, loop on `orca orchestration check`, or run watch scripts: waiting is free only while the turn is ended.
Why: a session that stays alive spends tokens; Orca wakes an ended one.

## Worker brief

Every brief is self-contained and states: repo and ticket key; the change wanted; the files the worker may edit; the
evidence of done (tests and lint commands of that repo); "work on a task branch `<KEY>-short-description`, open a PR,
never merge"; "set the worktree comment at each checkpoint"; and for a dependent repo, the upstream branch or PR.
