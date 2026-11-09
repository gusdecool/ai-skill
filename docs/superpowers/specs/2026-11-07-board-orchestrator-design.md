# Board orchestrator: watch workers and take over on a limit

## Why

The board dispatcher starts one `BOARD-WORKER` worker and exits. When that worker's provider hits its usage limit the
worker does not exit: it sits on a prompt ("Switch to gpt-6-luna?") and nothing notices. buzzly issue-7 stalled
this way on Codex; the 2-hour reaper only moves the card to HITL, it never finishes the work.

## What it becomes

The session the dispatcher starts is an orchestrator, an extension of the existing `load-balancer` skill, not a new
system. It plans, dispatches implementation tasks to workers on the best provider (load-balancer rules), watches
them, and takes over on another provider when one is stuck, until the ticket reaches QA or HITL.

## Decisions (from the user)

- The orchestrator is the only session that merges, and only through the existing `board-merge-gate`.
- Provider choice, cutoffs (90/95, reserved Claude 80/75) and takeover (stop, keep the draft, next provider at the
  same tier) are exactly the `load-balancer` rules. No new numbers.
- Waiting is done by a script, not by the model, so no tokens are spent while waiting.
- The orchestrator never answers a "switch model" prompt with "switch". It treats the prompt as a stall and takes over.

## Goals

- A worker that hits a limit is noticed within one poll (10 minutes) and its task continues on another provider.
- A healthy worker costs the orchestrator no tokens while it works.

## Non-goals

- No new provider ranking, no resuming a stuck worker in place, no changes to the merge gate.
- The orchestrator does not edit product code when the plan has two or more tasks.

## Parts

1. `board-watch <dispatch>:<provider>...` (new script, no model). Polls every `WATCH_INTERVAL` seconds (default 600)
   and exits on the first event, printing one JSON line `{event, dispatch, provider, reason, detail}`:
   - exit 0, event `settled`: the worker's stage is `settled` (it finished or failed).
   - exit 1, event `stuck`, reason one of `waiting_on_human` (Orca reports the worker parked on a human prompt),
     `limit_text` (a usage or rate limit phrase in the last 15 lines of its screen), `quota_cutoff` (its provider is
     over the load-balancer cutoff), `silent` (output unchanged for `SILENT_SECONDS`, default 600).
   - exit 2: Orca could not be read.
2. `pick-provider --orchestrator`: picks only claude, and only when it is under its reserved cutoffs. `board-precheck`
   uses it, so a run never starts when the orchestrator itself has no quota. Why: Claude's buffer is the reserved
   cutoff.
3. Skill text: `board-worker` step 4 becomes orchestrate-and-watch for plans of two or more tasks; the stop clock
   is 180 minutes (takeovers add time); the orchestrator posts an issue comment on every task finish, every takeover
   and at least hourly, because the 2-hour reaper reads issue and PR activity. `load-balancer` gains the screen-text
   and human-prompt signals and the 10-minute interval.
4. The dispatcher prompt calls `pick-provider --orchestrator`. Applied to the Orca automation after merge and
   `npx skills update -g`.

## My calls

- Interval 10 minutes (the skill said 5; the user said 10), as a setting.
- A one-task plan is implemented inline by the orchestrator, no worker.
- 180-minute cap instead of 90.
