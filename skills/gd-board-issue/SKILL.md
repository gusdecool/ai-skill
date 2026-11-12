---
name: gd-board-issue
description: Use when the user wants to create or groom a Jira ticket for the board worker ("write a board issue", "turn this idea into a ticket", "make this ready for the agent"). Turns a rough idea into a final-spec ticket the gd-board-worker can finish alone, checks it with the same readiness rules, creates it in Backlog and, only if the user says yes, ticks the Auto merge checkbox, and asks about Auto merge for any existing ticket that lacks it before queuing it. Not for BOARD-WORKER sessions.
license: MIT
metadata:
  author: gusdecool
  version: "1.0"
---

# Board issue

You help the user write one Jira ticket that an unattended agent can finish without asking anything. The ticket is the
final spec: every question is answered before it is created. Scripts live in `~/.agents/skills/gd-board-worker/scripts/`
and need the config from `gd-board-worker` (`~/.config/board-worker/config` and the Jira credentials file
`~/.config/board-worker/jira`; if missing, tell the user to run `board-setup`). Never print the Jira token.

Never use this skill in a session whose prompt starts with `BOARD-WORKER`: a worker must not write its own approval.

## Steps

1. **Understand.** Read the repo's README (the `## UAT` section), `AGENTS.md`/`CLAUDE.md` and the code the idea touches.
   Ask only what you cannot find out yourself.
2. **One question round.** Ask every remaining question at once, as choices: the options, your recommendation first,
   and each option's tradeoff in a line. No open questions with no options. The agent that works the ticket cannot ask
   the user, so anything left open becomes a guess. Also ask the priority (Highest, High, Medium, Low, Lowest;
   default Medium), and "Does a human have to set anything up outside the repo (apps, env, SSM, scopes)?" (default no;
   on yes, ask for each manual step and where it is done). Why: BM-56 (Facebook Pages) merged and deployed but could
   not work until the owner created the Meta app, and only the author knows such steps up front. Also ask which open
   tickets must be finished first (blockers). Offer the open tickets of the same repo or epic as options, with "none"
   as the default. Why: the dispatcher builds blockers first and reminds the
   user about blockers that are not queued, but only for blockers recorded as Jira links.
3. **Write the draft** to a temp file in Jira wiki markup, one ticket = one PR (split anything bigger), using this
   template:

   ```
   h2. Goal
   One or two sentences: what changes and why.

   h2. Acceptance criteria
   * Observable result 1 (what the user will check in UAT)

   h2. Constraints
   Files, APIs, libraries or rules to respect. Anything that must not change.
   Depends on: BM-12, BM-15 (only when the question round named blockers).

   h2. Decisions made
   The options chosen in the question round, with a short reason each.

   h2. Human setup
   Optional. Include it only when the question round found manual steps. One bullet per step, naming where it is
   done (service, console, SSM path, env name). Example: * Create the Meta developer app; set SSM /app/meta/secret.

   h2. Non-goals
   What this ticket must not do.

   h2. How to verify
   Commands or clicks that prove it works on UAT.

   h2. Open questions
   None.
   ```

   Leave the `h2. Human setup` section out when the answer was no. `board-check-ready` accepts the draft with or
   without it and does not treat it as an open question. Why: a ticket with this section ends in HITL, not QA, so the
   user is told to do the steps (BM-56 sat in QA, "ready to check", while it could not work).
4. **Check the draft.** Run `~/.agents/skills/gd-board-worker/scripts/board-check-ready --file <draft>` (wiki and
   Markdown headings both pass). It must print `"ready":true`; fix what it lists. Why: this is the exact check the
   dispatcher runs, so a draft that passes here is not bounced back to Backlog later.
5. **Warn before creating**, in plain words, when any of these is true (the merge gate will stop the PR; the user may
   still want the ticket):
   - the repo README has no `## UAT` section (the worker adds `UAT: unknown` and QA will not mean "on UAT");
   - the work touches CI/CD files (workflows, pipelines): these always need a human;
   - the work touches infrastructure files (Terraform, Dockerfiles, Kubernetes) and the config has
     `BOARD_ALLOW_INFRA_CHANGE` unset or `false`;
   - the repo is public and the config blocks `public` visibility (the ticket would be ignored).
6. **Ask about merging**, as its own question, default no: "Should the agent merge this itself once CI is green
   (the `Auto merge` checkbox)? Without it the PR stays open for you and the ticket moves to HITL." Tick it only when
   the user answers yes in this conversation; otherwise leave it unticked. Never decide it yourself. Why: the
   checkbox is the human approval that the merge gate checks.
7. **Create.** Show the final text and get an OK, then run
   `~/.agents/skills/gd-board-worker/scripts/board-ticket-cli create --summary <title> --component <owner/repo>
   --description-file <draft> --priority <priority>`. The component is the repo as `owner/repo`. It prints
   `{"key","url"}`. The ticket starts in Backlog, never Todo. Only if the user said yes in step 6, then run
   `board-ticket-cli automerge <key>`.
   For each blocker named in step 2, run `board-ticket-cli link <key> blocked-by <blocker-key>`.
8. **Status.** Leave it in Backlog. Move it to Todo (`board-set-status <key> Todo`) only if the user says to queue it
   now, or answers yes when you ask. Why: Todo starts the worker within 10 minutes, so it is the user's go signal.
   Before moving any existing ticket to Todo, read it with `board-ticket-cli view <key>`. If `autoMerge` is not `true`,
   ask the step 6 question first, default no, and on yes run `board-ticket-cli automerge <key>`. Why: an unticked box
   is a silent no, and the user should decide it once, not discover an unmerged PR later.
   When the user asks you to implement the ticket in this session, follow `gd-board-worker` for the steps and
   merge it as its "Merge permission" says: with the box ticked, run `board-merge-gate` after green CI and merge when
   it passes. Why: leaving the PR open after a ticked box ignores the user's decision.
9. **Report** the ticket URL, the status, the Auto merge value, the blockers linked and any warning from step 5.
   When the new ticket is moved to Todo while a blocker is still in Backlog, say that the dispatcher will move it
   to HITL until the blocker is queued.
