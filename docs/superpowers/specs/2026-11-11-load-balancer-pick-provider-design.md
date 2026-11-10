# Load balancer: a script picks the provider

Problem: in a real board run (ticket BM-55) the agent read the quotas with `orca account list --json`, saw Codex under
its cutoffs and dispatched to it at once. It never computed the urgency score. By the formula OpenCode Go (about 291)
beat Codex (about 213). Why it happened: the formula was prose in "Choosing the provider for a task", so a model could
shortcut "pick the highest score" to "first provider under its cutoff".

## Design

- `skills/load-balancer/scripts/pick-provider` (bash plus jq, no model) is the only place the formula lives. It reads
  `orca account list --json`, applies the cutoffs, computes remaining, timeLeftFraction (floor 0.05) and urgency per
  window, and prints JSON: every provider with each window's urgency, its score, whether it was skipped and why, the
  chosen provider, and a markdown score table.
- Options: `--reserved <provider|none>` (80 / 75 cutoffs), `--bump <provider>` (repeatable, +5 session points for
  parallel tasks), `--exclude <list>` (comma separated), `--orchestrator` (only the reserved provider, 90 in every
  window). The model still comes from `models.md`; the script knows no model names.
- `board-worker/scripts/pick-provider` stays the dispatcher's tier and model picker but calls the new script for the
  scoring, so the formula exists once.
- SKILL.md says: run the script, use its chosen provider, never choose by hand, and paste the score table into the
  dispatch comment or plan ledger. Why: a reviewer can then see the formula ran.
- Test: the BM-55 numbers (claude weekly 79 reserved, codex 62 / 58, opencodeGo 0 / 0 / 0, antigravity weekly 6)
  must choose opencodeGo.
