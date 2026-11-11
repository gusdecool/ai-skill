# Agent models plan

Spec: `docs/superpowers/specs/2026-11-11-agent-models-design.md`

### Task 1: board-run-stats labels and subagent logs
- [x] Add a label column to `model-prices.tsv`; add `label` per model and `startedAt` to `board-run-stats`; read `<session>/subagents/*.jsonl`; tests
### Task 2: ticket CLI and setup
- [x] `board-setup --stats-fields` creates the "Agent models" Labels field
- [x] `board-ticket-cli stats` merges labels, appends the `agent.runs` property, takes `--model`; add `runs <key>`; tests
### Task 3: skill text
- [x] Update `SKILL.md` of `gusdecool-board-worker` and `gusdecool-load-balancer`; run shellcheck, structure and tests
