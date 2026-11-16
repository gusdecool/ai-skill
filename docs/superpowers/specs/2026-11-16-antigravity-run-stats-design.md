# Record Antigravity (Gemini) worker usage on the ticket

## Problem
`ticket-record-stats` recorded an Antigravity worker with unknown numbers (`null`), because the skills said Gemini
usage cannot be read. It can: each Antigravity CLI conversation keeps a transcript
(`~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript_full.jsonl`) with `model`, `input_tokens`,
`output_tokens` and `cache_read_tokens` for every model step. BM-168 showed the cost: the worker's 34M tokens were
missing from the ticket. A session also passed a wrong `--since` and recorded its own run as zero.

## Behavior
- `board-run-stats <worktree> --provider antigravity --match <text> [--since <ISO>]` reads every transcript whose
  first user message contains `<text>` (the Orca task id, written into the worker's prompt) and prints the same JSON
  as the Codex path: one entry per model, tokens split into input, output and cacheRead, priced from
  `model-prices.tsv`.
- `ticket-record-stats --antigravity-match <text>` (repeatable) records each such worker, skips one already recorded
  with the same start time, and fails (exit 1) when no transcript matches.
- `model-prices.tsv` gets a `gemini-3.8-flash-medium` row (Gemini API Standard tier, checked 2026-11-16, source
  https://aistudio.google.com/docs/pricing; the price doubles on 2027-01-01).
- `--model` stays for providers with no readable logs (OpenCode).
- Antigravity runs on the user's Google AI Pro quota, so the dollar figure is the API-equivalent value, not cash.

## Why match on text
The transcript has no working directory, so a worktree path cannot find it. The task id is unique per worker.
