# Load balancer weekly-only scoring plan

Spec: `docs/superpowers/specs/2026-11-15-load-balancer-weekly-scoring-design.md`

### Task 1: Script
- [x] Defaults: reserved 50 in every window, others 90; pause check always 90.
- [x] Score is the weekly urgency; a provider with no weekly window is skipped; `--bump` moves session and weekly.

### Task 2: Tests
- [x] Update the BM-55 expectations; add weekly-only score, bump on weekly, session 90 guard, no weekly window,
  pause check ignoring `main_cutoff`.

### Task 3: Skill text
- [x] Update `SKILL.md` cutoffs, urgency, worked example and pause trigger.
