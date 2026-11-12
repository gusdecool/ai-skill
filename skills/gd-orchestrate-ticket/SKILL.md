---
name: gd-orchestrate-ticket
description: Use when an Orca worktree session is given a Jira ticket to orchestrate, or the ticket touches other repos. Maps components to repos, starts a worker per repo in dependency order, tracks them, reports PRs. Never merges.
license: MIT
metadata:
  author: gusdecool
  version: "1.0"
---

# Orchestrate a ticket across repos

This session is the orchestrator. It plans and tracks; the workers change code in their own repos. Needs the `orca`
CLI (load `orca-cli` and `orchestration` for command details), `board-ticket-cli` from `gd-board-worker`, and
`jq`. Name no model here: the model comes from `pick-provider` (step 5).

## Steps

1. **Read the ticket.** `board-ticket-cli view <KEY>` gives `components`, `description`, `summary`. With no
   components, ask the owner which repos are touched.
2. **Map components to repos.** `scripts/ticket-repos <component>...` (next to this file) prints
   `{component, repoId, path}` per component; exit 3 means some are `null` (no match or two repos share the name).
   Overrides live in `~/.config/orchestrate-ticket/repos` as `component=repo-display-name` lines.
3. **Confirm once.** Show the repo list and the dependency order you propose (for example API before client). Ask the
   owner one question: confirm, add or remove repos, or name the repo for an unmatched component. Options, your
   recommendation first, tradeoff per option. State the time estimate for the whole ticket in the same message
   (it is a guess until the repos are read; say so). After the answer, do not ask again.
4. **Write the plan.** `tickets/<KEY>/plan.md` in this repo: repos, one self-contained brief per repo, dependencies,
   and a status table (repo, worker, PR URL, state). Commit it on this worktree's task branch. Why: a new session
   resumes from the file, not from chat.
5. **Start the workers with no open dependency.** First load `gd-model-policy` and `gd-load-balancer`. Why: an
   orchestrator that skipped them picked a Claude worker by hand and ignored the quota formula. For each worker:
   - Run `gd-load-balancer/scripts/pick-provider --reserved <your provider> --tier <tier>`. Never choose the provider,
     agent or model by hand. Run it again with `--bump <provider>` for each further worker started in the same batch.
   - Paste the printed `table` into the plan file's status section.
   - Worker or subagent: a repo that is not this worktree, or a `chosen` provider other than your own, gets an Orca
     worker. A `chosen` provider equal to your own, for work that fits this worktree, gets a subagent pinned as
     `gd-model-policy` says.
   - Start the worker with
     `orca orchestration worker-start --worktree new-top-level --repo id:<repoId> --name <KEY>-<repo> --agent <agent>
     --model <model> --spec-file <brief file>` using the printed `agent` and `model`.
   - Link it under this worktree: `orca worktree set --worktree <its id> --parent-worktree active`. Take the id
     from the receipt, or from `orca worktree list --repo id:<repoId> --json` by name.
   Then **end your turn**.
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
