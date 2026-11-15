# Load balancer: weekly-only scoring and simpler cutoffs

Decided by the owner on 2026-11-15, in the AI-skill-load-balancer notes session.

## Rules

- Orchestrator (the caller's own provider): cutoff 50% on session and weekly. Above it, the orchestrator hands
  implementation tasks to workers. It keeps planning and reviewing until 90%, then the pause procedure starts.
  Why: the owner wants the quota for orchestration.
- Workers: score on the weekly window only (`remaining / timeLeftFraction`), so the weekly quota is used up before it
  resets. Session and monthly only gate eligibility. Cutoff is 90% in every window.
  Why: a worker whose session fills is taken over by another worker; the 90 guard avoids sending a task to a provider
  that is nearly out.
- OpenCode Go keeps its 50% cutoff on session, weekly and monthly (user config). Why: the quota is shared with Hermes,
  and the owner is still measuring Hermes' share. Monthly stays for now.
- Antigravity (AI Pro) now reports a 5-hour session and a weekly window. The top-level numbers are used; the per-model
  buckets (Gemini Models, Claude and GPT models, Gemini 4 Argon) are not. Why: no code change, simplest.
- Defaults live in the script; `~/.config/load-balancer/config.json` only overrides them. `main_cutoff` no longer
  changes the pause check (always 90).
- `--bump` adds 5 points to session and weekly, because the score now reads the weekly window.
