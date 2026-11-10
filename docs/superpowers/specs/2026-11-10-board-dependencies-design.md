# Board ticket dependencies: design

## Intent and why

Some tickets must be built in order (for example an API endpoint before the web page that calls it). Today the
board worker ignores order: it takes the next Todo ticket by priority, so a dependent ticket can start before its
blocker exists and fail or stall. The owner decided that tickets declare dependencies in Jira, and that the
dispatcher honors them.

## Decided (by the owner)

- A ticket depends on another through the Jira link type `Blocks` ("is blocked by"). Other link types are ignored.
- A blocker counts as finished when its status is QA or Done. QA means merged and deployed to UAT, so the dependent
  builds on real code.
- If a ticket in Todo has an unfinished blocker that is itself in Todo, the dispatcher picks the blocker first
  (and its own blockers before that).
- If an unfinished blocker is in In progress, the dependent is skipped quietly and checked again on the next tick.
- If an unfinished blocker is in any other status (Backlog, HITL and so on), the dependent moves to HITL with a
  comment naming the blocker, so the owner is reminded.
- A dependency cycle moves every ticket in the cycle to HITL with a comment showing the cycle.
- `board-issue` asks, in its single question round, which tickets block the new one, and creates the links.
- The rename of `board-ticket` to `board-ticket-cli` ships first, in its own pull request.

## Behavior

`board-ticket-cli` gets two subcommands:

- `link <key> blocked-by <blocker-key>`: creates the `Blocks` link. Does nothing when the link exists. Refuses a
  ticket linked to itself.
- `blockers <key>`: prints a JSON array of `{key, status, finished}`, one per `Blocks` link where the ticket is the
  blocked one. `finished` is true for QA and Done.

`board-pick-next` reads `issuelinks` with the Todo search (Jira returns the linked ticket's status in the same
answer), then walks from the best candidate:

1. No unfinished blocker: the candidate is taken, as today.
2. Any unfinished blocker not in Todo or In progress, or in Todo but of a repo whose owner is not allowed: park the
   candidate in HITL.
3. Else any blocker In progress: skip the candidate, no change.
4. Else all unfinished blockers are in Todo: continue the walk from the lowest-numbered blocker.
5. A ticket met twice on one walk is a cycle: park every ticket on the walk.

A ticket parked during a run counts as HITL for the rest of that run, so a dependent is parked once with the right
reason and not sent to a blocker that was just parked. `--dry-run` changes nothing, as before.

## Non-goals

- No change to what the worker does once it has a ticket.
- No automatic moves of dependents to Todo when a blocker reaches QA. The owner queues them.
- No dependency graph view.
