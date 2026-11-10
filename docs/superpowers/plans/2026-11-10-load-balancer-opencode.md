# Load balancer: OpenCode Go provider

Spec: the owner subscribed to OpenCode Go (2026-11-10) and wants DeepSeek V4.1 Flash (Low) and V4 Pro (Mid) used by
the load-balancer skill. Choices: add the `monthly` window to the urgency score, cutoffs 95 for monthly (75 for the
reserved provider), slugs live in `agent-standards` `models.md`, and a `worker-start` test before writing the adapter.

### Task 1: Verify OpenCode Go in Orca (mechanical)
- [x] `orca account list --json` reads `opencodeGo` with session, weekly and monthly windows (status ok)
- [x] `orca agent launch --agent opencode --model opencode-go/deepseek-v4.1-flash` and `deepseek-v4-pro` answer `ok`
- [x] `orca orchestration worker-start --agent opencode --model opencode-go/deepseek-v4.1-flash` finishes (succeeded)

### Task 2: Add the OpenCode adapter to the skill (mechanical)
- [x] Add `opencodeGo`, the monthly window and its cutoffs to the skill
- [x] Add the launch command, the slug pointer and the Global region note to the Orca adapter
- [x] Run `tests/check-structure.sh`
