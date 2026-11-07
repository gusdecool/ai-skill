---
name: board-issue
description: Use when the user wants to create or groom a GitHub issue for the board worker ("write a board issue", "turn this idea into a ticket", "make this ready for the agent"). Turns a rough idea into a final-spec issue the board-worker can finish alone, checks it with the same readiness rules, adds it to the project and, only if the user says yes, sets Auto merge, and asks about Auto merge for any existing issue that lacks the line before queuing it. Not for BOARD-WORKER sessions.
---

# Board issue

You help the user write one issue that an unattended agent can finish without asking anything. The issue is the final
spec: every question is answered before it is created. Scripts live in `~/.agents/skills/board-worker/scripts/` and
need the config from `board-worker` (`~/.config/board-worker/config`; if missing, tell the user to run `board-setup`).

Never use this skill in a session whose prompt starts with `BOARD-WORKER`: a worker must not write its own approval.

## Steps

1. **Understand.** Read the repo's README (the `## UAT` section), `AGENTS.md`/`CLAUDE.md` and the code the idea touches.
   Ask only what you cannot find out yourself.
2. **One question round.** Ask every remaining question at once, as choices: the options, your recommendation first,
   and each option's tradeoff in a line. No open questions with no options. The agent that works the ticket cannot ask
   the user, so anything left open becomes a guess.
3. **Write the draft** to a temp file, one ticket = one PR (split anything bigger), using this template:

   ```
   ## Goal
   One or two sentences: what changes and why.

   ## Acceptance criteria
   - Observable result 1 (what the user will check in UAT)

   ## Constraints
   Files, APIs, libraries or rules to respect. Anything that must not change.

   ## Decisions made
   The options chosen in the question round, with a short reason each.

   ## Non-goals
   What this ticket must not do.

   ## How to verify
   Commands or clicks that prove it works on UAT.

   ## Open questions
   None.

   Auto merge: false
   ```

4. **Check the draft.** Run `~/.agents/skills/board-worker/scripts/board-check-ready --file <draft>`. It must print
   `"ready":true`; fix what it lists. Why: this is the exact check the dispatcher runs, so a draft that passes here is
   not bounced back to Backlog later.
5. **Warn before creating**, in plain words, when any of these is true (the merge gate will stop the PR; the user may
   still want the ticket):
   - the repo README has no `## UAT` section (the worker adds `UAT: unknown` and QA will not mean "on UAT");
   - the work touches CI/CD files (workflows, pipelines): these always need a human;
   - the work touches infrastructure files (Terraform, Dockerfiles, Kubernetes) and the config has
     `BOARD_ALLOW_INFRA_CHANGE` unset or `false`;
   - the repo is public and the config blocks `public` visibility (the card would be ignored).
6. **Ask about merging**, as its own question, default no: "Should the agent merge this itself once CI is green
   (`Auto merge: true`)? Without it the PR stays open for you and the card moves to the HITL column." Write
   `Auto merge: true` only when the user answers yes in this conversation; otherwise leave `Auto merge: false`. Never
   decide it yourself. Why: the line is the human approval that the merge gate checks.
7. **Create.** Show the final text and get an OK, then
   `gh issue create --repo <owner/repo> --title <title> --body-file <draft>`. Then add it to the project from the
   config:
   `gh project item-add <BOARD_PROJECT> --owner <BOARD_OWNER> --url <issue-url>`, and set Priority (and Iteration if
   the user uses it) with `gh project item-edit`, reading field and option ids from
   `gh project field-list <BOARD_PROJECT> --owner <BOARD_OWNER> --format json`.
8. **Status.** Run `board-set-status <issue-url> Backlog`. Move it to Todo only if the user says to queue it now, or
   answers yes when you ask. Why: Todo starts the worker within 10 minutes, so it is the user's go signal.
   Before moving any card to Todo, read the issue body. If it has no `Auto merge:` line (an issue written by hand, or
   one from before this rule), ask the step 6 question first, default no. On yes, append `Auto merge: true` to the body
   with `gh issue edit` as the user's own account; on no, append `Auto merge: false`. Why: a missing line is a silent
   no, and the user should decide it once, not discover an unmerged PR later.
9. **Report** the issue URL, the card status, the Auto merge value and any warning from step 5.
