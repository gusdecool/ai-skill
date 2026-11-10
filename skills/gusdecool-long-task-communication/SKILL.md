---
name: gusdecool-long-task-communication
description: Use when a task will take more than about 20 minutes, when a task leaves two or more follow-up steps for the user, or when a step is blocked by a limit that lifts on its own. State the estimate first, publish a follow-up checklist artifact, and ask once with options before waiting out a limit.
---

# Long task communication

Set the user's expectations before long or blocked work so they can leave and come back at the right time, and never
wonder whether stalled work is finished. Three rules: state an estimate first, leave a follow-up checklist, and ask
once (with options) before waiting out a limit.

## State the estimate first

Before starting a long task — one you expect to take more than about 20 minutes: a multi-step plan, a big refactor,
a long test or build run — say how long you expect it to take and at what clock time it will be done. Base the
estimate on the plan's steps. Mark it as an estimate, not a promise. If it slips by more than about a third, say so
with the new finish time.

- Get the current time from the system (`date`) instead of guessing, and give the finish time in the user's local
  time zone (the one `date` reports), for example "about 40 minutes, done around 15:20 local time".

### Hard gate

The estimate is the first thing you write, before the first tool call that edits files, installs or runs anything
beyond reading. A promise to give it later does not count; saying it with the work already started does not count
either.

### After the clarifying round

The gate also applies right after the clarifying-questions round: when the user answers and you begin implementing,
the first message after the answers states the estimate, then you start. Do not let "implement end to end without
further check-ins" skip it.

### Self-check before the first edit

Before the first edit of every task, ask: "Is this over about 20 minutes, and did I already state the estimate?" If
not, stop and state it first. If you notice you skipped it, give it at once with the current elapsed time and the
new finish time, and say you skipped it.

## Follow-up checklist for the user

When a task leaves two or more follow-up steps for the user (after merge: apply, create a key, configure, test),
publish them as a checklist Artifact the user can keep open: a checkbox per step, who does it (user or agent), and a
copy button for each command. Republish to the same URL with a step ticked when the agent finishes it. Keep the chat
summary short and link the artifact.

## Blocked by a limit that lifts on its own

When a step is blocked by a limit that lifts on its own (GitHub rate limit, API quota, a long CI run), stop and ask
once, with options, before waiting. Give the real reset time (for GitHub, from `gh api rate_limit`, not a guess) and
offer:

1. a local watcher, a background loop or scheduled wakeup — good for short waits, but it dies when the computer
   sleeps;
2. a scheduled cloud agent, which survives sleep;
3. wait in the session.

Once the user picks, resume the task alone and report the result, with no further check-in. Why: a silent retry loop
can die unnoticed, and the user cannot tell stalled work from finished work.
