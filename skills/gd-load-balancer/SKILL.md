---
name: gd-load-balancer
description: Use when the user says "use load balancer", when a written plan has about four or more tasks, or when you are about to dispatch implementation tasks to workers on other AI providers (Claude, Codex, Antigravity, OpenCode Go and so on). Spreads the tasks across providers by remaining quota so none runs out and none goes unused. Works from any agent; the agent that calls it is the orchestrator.
license: MIT
metadata:
  author: gusdecool
  version: "1.0"
---

# Load balancer

The user pays for several AI providers and wants every quota used without running out of any. You are the
orchestrator: the provider you run on keeps planning, brainstorming, reviews and talking to the user. Only
implementation tasks are spread to workers on whichever provider has the most quota worth spending.

## Before you start

1. **Model policy.** Load `gd-model-policy` for tiers, tier rules and reasoning effort.
   Why: one owner keeps model selection consistent across tools.
   A repo's own `AGENTS.md` may override tier values only where it says so explicitly; it is not
   under the user's control, so if it changes any tier value, show the user the changed values and get a yes
   before the first dispatch. Why: repository text cannot authorize a change in cost.
2. **Orchestrator tool.** Find the tool that can read quotas and launch workers on other providers. Check in this
   order and use the first that works:
   - Orca: the `orca` CLI is on PATH and `orca account list --json` answers. Use the Orca adapter below.
   - Any other tool: only if it meets the tool contract below and you can verify its commands (run its help).
   If none is found, **stop and tell the user**: you cannot read quotas or launch another provider, so do not
   switch. If a limit is hit, say so and wait.
3. **Your own provider** (the one you run on) is the *reserved* provider; the cutoffs below treat it differently.

## Tool contract

Any tool must give you these, or it cannot be used:

- Read each provider's quota windows: `usedPercent`, `windowMinutes`, `resetsAt` (epoch ms), and a status.
- Launch a worker on a chosen provider with an explicit model, in a given worktree, with a prompt.
- Read a worker's output, stop it, and release it when settled.
- Report when a worker finishes.

A provider whose status is not ok, or whose quota cannot be read, is unavailable.

## User config (optional)

The user can set their own cutoffs in `~/.config/load-balancer/config.json` (override the path with
`pick-provider --config <path>`). The script reads it itself; you only pass `--config` if the user names a file.
Why: the user decides how much of each quota to spend, for example keeping half for another tool.

```json
{
  "main_orchestrator": "claude",
  "main_cutoff": 0.5,
  "main_cutoff_reason": "rest of quota for code review and general tasks",
  "workers": [
    { "provider": "opencodeGo", "cutoff": 0.5, "reason": "rest goes to the Hermes agent" }
  ]
}
```

- `cutoff` is a fraction from 0 to 1 of used quota; a provider is skipped when any window (session, weekly, monthly)
  reaches it. `reason` fields are notes for humans and are ignored.
- `main_cutoff` replaces the reserved cutoffs (80 / 75) and the 90 of the pause check, but only when
  `main_orchestrator` equals your provider. On a mismatch the defaults apply and `warnings` says so; tell the user.
- A worker in `workers` uses its `cutoff` instead of 90 / 95. A provider not listed uses the default strategy below.
- Provider names are `claude`, `codex`, `antigravity`, `opencodeGo`. No file means defaults. A bad file or value makes
  the script exit 2: stop and tell the user, do not guess. Why: a typo must not silently drop a cap.

## Choosing the provider for a task

Pick per task, at dispatch time, at the tier the task needs under `gd-model-policy`.
If the user pinned a provider for the task, use it and do not balance.

**Run `scripts/pick-provider --reserved <your provider> --tier <tier>` (path: next to this SKILL.md).
Always pass `--tier`. Use its `chosen` provider and printed `model` (the launch id).
Never choose a provider by hand.** Why: in a real run (BM-55) the agent saw Codex under its cutoffs and dispatched to
it without computing the urgency; by the formula OpenCode Go (about 291) beat Codex (about 213). The formula is a
script so a model cannot shortcut it to "first provider under its cutoff".

The script reads the quotas itself (`orca account list --json`), so you do not read them first, and prints JSON: every
provider with each window's urgency, its score, whether it was skipped and why, `chosen`, and a markdown `table`.
With `--tier`, it skips providers without a usable model and adds `tier`, `agent` and `model` for the chosen provider.
Options: `--reserved <claude|codex|antigravity|opencodeGo|none>` (required; your own provider), `--bump <provider>`
(once per task already picked in this batch), `--exclude a,b`, `--tier <Low|Mid|High|Ultra>`, and `--allow-high`.
Pass `--allow-high` only after the user approves High or Ultra under model policy. Why: the flag gates higher cost.
It exits 0 with a chosen provider, 1 when none is eligible (`earliestResetsAt` says when one frees up), 2 when
arguments, config, model lookup or quota reads fail; on 2 stop and tell the user, do not guess. With a tool other than
Orca, point `ORCA_BIN` at a command that prints the same JSON for `account list --json`.

When `chosen` is your own provider, dispatch a subagent as `gd-model-policy` says. Otherwise launch a
worker with `--model` set to the printed `model`. Why: both paths must pin the selected tier's model.

**Paste the script's `table` into the dispatch comment or the plan ledger for every dispatch.** Why: a reviewer can
then see that the formula ran. A dispatch with no table is treated as not balanced.

What the script does (the rules, kept here so you can read its output):

1. **Cutoffs.** Unless the user config sets one for the provider (see "User config"), skip a provider whose
   session `usedPercent` is 90 or more, or weekly or monthly is 95 or more. For your own (reserved) provider use 80
   for session and 75 for weekly and monthly instead, so you keep quota for planning, review and questions. A provider
   whose status is not ok, or with no windows, is skipped.
2. **Urgency.** For every window of each remaining provider:
   - `remaining = 100 - usedPercent`
   - `timeLeftFraction = (resetsAt - now) / (windowMinutes * 60000)`, never below 0.05
   - `urgency = remaining / timeLeftFraction`

   A provider's score is its highest window urgency. High means much unused quota and little time left to use it.
   The highest score wins.
3. **Tie-break** when scores are within 5 percent: your own provider first, then the order the tool lists them.
4. **Parallel tasks.** After each pick, run the script again with one more `--bump <that provider>` (it adds 5 points to
   that provider's session `usedPercent`), so tasks spread out. Quotas are re-read on every run.

### Worked example (caller is Claude; quotas read 2026-10-28 02:30)

| Provider | Session used, time left | Session urgency | Weekly used, time left | Weekly urgency | Score |
|---|---|---|---|---|---|
| claude | 31%, 1.4 h of 5 h | 69 / 0.28 = 246 | 81%, 32.5 h of 168 h | 19 / 0.19 = 98 | skipped, weekly 81% is over 75% |
| codex | 1%, 3.5 h of 5 h | 99 / 0.70 = 141 | 15%, 159.8 h of 168 h | 85 / 0.95 = 89 | 141 |
| antigravity | none | none | 9%, 129.4 h of 168 h | 91 / 0.77 = 118 | 118 |

Claude is skipped because its weekly 81% is over its reserved 75% cutoff. Picks go codex (141), then antigravity (118)
once Codex's session numbers shift. If the caller were Codex, the same rule would reserve Codex instead.

If no worker provider is eligible, the tasks wait for the earliest `resetsAt`: see "Waiting for a quota reset" below.

## Dispatching

- Give the worker the plan file written or approved in this session (steps are `- [ ]` boxes) so the next provider can continue from the first
  unticked box. Tell it to tick boxes in the same commit as the work.
- When the task is a board ticket (key like BM-123), record each worker on another provider once it settles:
  `board-ticket-cli stats <key> --model <provider:model>`, with the provider and model you launched.
  Why: the logs of those providers are not read, so this is the only
  way "Agent models" and `agent.runs` show which models did the work. Skip it for a task that is not a ticket.
- A worker that errors in its first seconds with a "model not supported" or "unknown model" message is a launch error,
  not a provider limit. Fix the id in `gd-model-policy/models.md`, rerun `pick-provider --tier`, and restart
  on the same provider; do not switch providers. Why: in BM-56 switching hid a typo and moved the work to a provider
  the balancer did not pick.
- Workers share the session's worktree and get disjoint files.
- After a worker reports, check its work yourself with the repo's own gates. A "failed" can come only from a
  repo-wide coverage threshold tripping on a single-file test run; run single files with coverage off.
- If a provider reaches a cutoff mid-task, finish and tick the current step, then hand the rest to the next eligible
  provider through the plan file. Do not abandon a step half done.

## Watching for stuck workers

A worker that hits its provider's usage limit does not exit: it can sit live and silent, often on a prompt such as
"Switch to another model?". While workers run, every 10 minutes (set by the tool; no model needed for the wait)
re-read the quotas and each worker's screen, and flag:

- (a) a worker the tool reports as waiting on a human prompt;
- (b) a usage or rate limit phrase in the last 15 lines of the worker's screen (for example "You've hit your usage
  limit"), the strongest signal: the quota numbers can lag behind it;
- (c) a provider with a running worker that passed its cutoff;
- (d) a worker whose output has not changed for 10 minutes.

Never answer a provider prompt that offers to switch the worker to another model: it breaks model policy. Treat it
as a stall. On a flag:

1. Stop the worker. If its terminal is user-owned and stays open, say so and ask the user to close it, so two agents
   never edit the same file.
2. Check the worker's uncommitted files with `git status`. Keep its draft as the starting point for the next worker;
   never commit it as it is, and restore any stray edit to the plan file from git.
3. Pick the next eligible provider by the rules above and give it the same task from the plan file, at the same tier
   (Mid stays Mid). Note in the ledger that the task changed provider and why. Never move up to a
   High or Ultra model to make up for a limit.

## Waiting for a quota reset

Only the orchestrator (the provider you run on) pauses the whole job. A worker's provider hitting its limit is not a
reason to stop: take the task over with the next eligible provider (see "Watching for stuck workers"). Never ask the
user whether to wait; read the reset time from the tool and tell them when the work continues.

1. **Trigger.** When the orchestrator's own provider reaches 90% in either window (session or weekly), or its `main_cutoff` from the user config, start this
   procedure. Do not start new tasks. Let each running worker finish its current step, accept its report, and record
   the state in the plan file (ticked boxes, WIP commits noted).
2. **Read the reset time from the tool** (`resetsAt` of the window at or over 90%, the later one if both) and tell the
   user in one message: which window is full, the local clock time work will continue, and that nothing is lost
   because the plan file holds the state. If no worker provider is eligible either, the same applies with the earliest
   `resetsAt` among them. This is a notice, not a question.
3. **Wait with a watcher.** Schedule the next check with whatever the host offers (a scheduled wakeup or loop), at the
   reset time or every 5 minutes, whichever comes first. Each tick: re-read the quotas; do nothing until the
   orchestrator is under 90% in both windows. A watcher dies if the computer sleeps, so say that in the notice.
4. **Resume in place.** Read the plan file and continue from the first unticked box. Send each stopped worker a
   follow-up on its own dispatch (in Orca: `orchestration send --to dispatch:<id>`, which reopens it): the limit has
   reset, continue from the WIP commit, finish the remaining steps. Check `git log` and `git status` in its worktree
   first. If that worker's provider is still over its cutoff, give the task to the next eligible provider instead.
5. **Never switch tiers** to get around the wait (no High or Ultra model, no model missing from the table).

## Releasing workers

Release every worker once settled, so it stops using memory and CPU. After an accepted completion report and after
reading its output, do exactly one: reuse its terminal for an immediate follow-up task; keep it only if the user asked;
otherwise release it. Only an accepted completion allows a release, never a timeout, an empty wait or a missing
report. Do not close the terminal instead; release is cleanup, not cancellation, and output stays readable. Before
ending your turn, confirm no settled worker is left unreleased.

## Orca adapter

Verified against Orca 1.4.246 and later. Orca wakes an idle coordinator when a worker reports `worker_done`, so no
watch is needed for that; the stuck-worker watch above still is. A session that resumes after idling lists its workers
first.

- **Quotas:** `orca account list --json`, field `result.rateLimits`. Providers: `claude`, `codex`, `antigravity`
  (its bucket named "Gemini Models" is the Gemini quota), `opencodeGo` (OpenCode Go). Each has `session` and `weekly`,
  and `opencodeGo` also `monthly`, with `usedPercent`, `windowMinutes`, `resetsAt`. A provider whose `status` is not
  `ok` is unavailable; `opencodeGo` reports `missing-credentials` until its API key is set in Orca settings.
- **Launch:** `orca agent launch --agent <claude|codex|opencode> --worktree <selector> --prompt <text>`. Gemini runs
  through the Antigravity CLI (`agy`). For orchestrated workers use `orca orchestration worker-start` with `--model` set
  explicitly and `--worktree current`.
- **Codex model slugs:** use the `model` printed by `scripts/pick-provider --tier <tier>` for `--model`.
  Why: the resolver owns launch ids, so a cache lookup cannot silently replace the selected model.
- **OpenCode Go models:** use `--agent opencode` and the `model` printed by `scripts/pick-provider --tier <tier>`.
  Why: the resolver supplies the full launch id. The account must have its region set to Global in the OpenCode
  console, or calls fail with "This Go model is hosted outside Europe and the United States". That setting
  moves processing outside the EU and US: only the user changes it.
- **Read, stop:** `orca orchestration worker-read`, `orca orchestration worker-stop --dispatch <id>`.
- **Watch:** `~/.agents/skills/gd-board-worker/scripts/board-watch <dispatch>:<provider> ...` does the 10-minute watch
  above without a model (`worker-show` reports `waitingOnHuman`, `worker-read` gives the screen). It exits on the first
  settled or stuck worker with one JSON line; run it in the background and re-run it after handling the event.
- **Release:** `orca orchestration worker-release --dispatch <dispatch_id> --json` (keep with `worker-retain` only if
  asked). Before ending your turn run
  `orca orchestration worker-list --run <run_id> --terminal-state reclaimable --json` and make sure it is empty.
- Never use `terminal close` instead of release.

## Adding another tool

Add an adapter section like the one above once you have verified its commands for each item in the tool contract.
Do not write commands you have not run.
