# Board run stats: time, tokens and cost on the Jira ticket

## Goal
After a board worker ends a ticket (QA or stopped), the ticket shows how long the run took and what it cost, so the
owner can see and sum it in Jira.

## Design
- New script `board-run-stats <worktree> --since <ISO>`: reads the Claude Code session logs of that worktree
  (`~/.claude/projects/<path with non-alphanumerics as '-'>/*.jsonl`), counts each assistant message once, sums tokens
  per model, prices them with `model-prices.tsv`, and prints JSON with a markdown summary. Exit 0 even with no logs.
- New `board-ticket-cli stats <key>`: reads that JSON on stdin, adds minutes, tokens and cost to three Jira number
  fields, and posts the markdown as a comment. A missing field is skipped with a warning; the comment is still posted.
- `board-setup --stats-fields`: creates the fields when missing and adds them to every screen that holds "Auto merge"
  (needs a Jira admin token).
- `SKILL.md`: a "Run stats" step on every exit path, just before the status move. Stats never block or fail a ticket.

| Jira field | Type | Meaning |
|---|---|---|
| Agent minutes | number | First to last logged message, summed over runs |
| Agent tokens | number | Input + output + cache read + cache write tokens, summed over runs |
| Agent cost USD | number | Estimated: tokens times list price from `model-prices.tsv`, summed over runs |

## Not covered
- Workers on Codex or Gemini and takeovers in another worktree (no reader yet). Claude only.
- A worker that crashes before its last step posts nothing; a catch-all pass in `board-cleanup` is a follow-up.
- Cost is an estimate. Cache write price (1.25 x input) and the Haiku 5.5 cache read price are assumptions noted in
  `model-prices.tsv`.
