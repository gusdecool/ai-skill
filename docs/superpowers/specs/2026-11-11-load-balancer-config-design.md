# Load balancer: user config for cutoffs

Problem: the cutoffs in `pick-provider` are fixed (90 / 95 for workers, 80 / 75 for the reserved provider). The user
wants to decide per provider where to stop, for example to keep half of a quota for another tool.

## Design

- A JSON config file, default `~/.config/load-balancer/config.json`, override with `pick-provider --config <path>`.
- Schema (`reason` fields are for humans and ignored by the script):

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

- `cutoff` is a fraction from 0 to 1 of used quota. A provider is skipped when ANY window (session, weekly, monthly)
  has `usedPercent >= cutoff * 100`.
- `main_cutoff` replaces all reserved-provider cutoffs (80 session, 75 weekly/monthly) and the 90 used by
  `--orchestrator` (the pause check), but only when `main_orchestrator` equals `--reserved`. On a mismatch the
  defaults apply and a warning goes to stderr and to the `warnings` array of the JSON output.
- A worker listed in `workers` uses its `cutoff` in place of 90 / 95. Unlisted providers use the defaults.
- Provider names are the script's: `claude`, `codex`, `antigravity`, `opencodeGo`. No aliases.
- Missing default-path file means defaults. A malformed file, an unknown provider, a cutoff that is not a number from 0
  to 1, a `main_orchestrator` without `main_cutoff`, or an explicit `--config` path that does not exist exits 2 with a
  message. Why: a typo must not silently drop a cap meant to protect a quota.
- The skipped reason of a configured provider ends in `(config)`.
