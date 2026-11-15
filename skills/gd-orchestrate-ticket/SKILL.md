---
name: gd-orchestrate-ticket
description: Use when a session is given a Jira ticket URL or key (for example BM-165) to work on, in an Orca worktree, or when the ticket touches a repo other than the current one. Maps components to repos, starts a worker per repo in dependency order, tracks them, reports PRs. Never merges.
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

1. **Run the gate.** `scripts/ticket-gate <KEY>` (next to this file) reads the ticket and prints
   `{ask, missing, repos}`. It runs `board-check-ready` (goal, acceptance criteria, no open questions, one component)
   and `board-ticket-cli blockers` (no blocker ticket is unfinished), and `ticket-repos` (every component maps to
   exactly one repo; overrides live in `~/.config/orchestrate-ticket/repos` as `component=repo-display-name` lines).
   Exit 0 means `ask` is false.
   `board-ticket-cli view <KEY>` gives the full text for the briefs. Why: a ticket made with `gd-board-issue` is built
   so nobody is asked anything; a session once asked a confirmation on such a ticket because this step asked every
   time.
2. **Decide from the gate, never from habit.**
   - `ask` is false: do not ask the owner anything. Put the repos, the dependency order (from the ticket's "Depends on"
     line, else the order of the components) and the time estimate in one short chat message, and go to step 4 in the
     same turn. The ticket is the owner's decision.
   - `ask` is true: ask the owner once, as one question per gap named in `missing`. Options, your recommendation first,
     tradeoff per option (for "Repo mapping": name the repo for the unmatched component; for a missing section or open
     question: answer it or stop; for "Blocker <KEY>": ask whether to resolve that blocker ticket first with this skill,
     recommended, then come back to this ticket, or to continue anyway with the cost of building on something that does
     not exist yet, or to stop. Resolve the blocker the same way, gate included, and never start the blocked ticket's
     workers until the owner has answered). State the time estimate in the same message (a guess until the repos are
     read; say so). After the answer, do not ask again.
3. **Never add a question the gate did not ask for**, such as "start the worker?" or "add another repo?". A blocker is
   asked about only through the gate's "Blocker <KEY>" entry. Why: each extra question makes the owner answer something
   the ticket already decided. Why blockers are asked: BM-206 (Hermes on node 2) was built and merged while its blocker
   BM-204 (create node 2) was still in Backlog, so the first apply created nothing to run on and the owner found the
   missing EC2 instance first.
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
   report each repo's PR as a full URL with outcome and open blockers. Do not merge anything. Before you report a PR
   as done, load `gd-git-workflow` and check it: `gh pr checks <n> --repo <repo>` all pass and
   `gh pr view <n> --repo <repo> --json mergeable,mergeStateStatus` is `MERGEABLE` and `CLEAN`. A failing or pending
   check, or a conflict, is a blocker, not "done". Why: a session reported a PR with a failing CI check as done
   because this step only said to list the PRs.

Never poll, loop on `orca orchestration check`, or run watch scripts: waiting is free only while the turn is ended.
Why: a session that stays alive spends tokens; Orca wakes an ended one.

## Worker brief

Every brief is self-contained and states: repo and ticket key; the change wanted; the files the worker may edit; the
evidence of done (tests and lint commands of that repo); "work on a task branch `<KEY>-short-description`, open a PR,
never merge"; "set the worktree comment at each checkpoint"; and for a dependent repo, the upstream branch or PR.
