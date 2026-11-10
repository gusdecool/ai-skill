# Load balancer: waiting for a quota reset

Spec: the owner asked (2026-11-10) that the local watcher used during the abaku MVP loop be standardized in the
load-balancer skill. Why: when every provider hit its limit, the skill only said "stop and tell the user", and the
resume steps were improvised.

### Task 1: Add the "Waiting for a quota reset" section (mechanical)
- [x] Replace the stop line with a pointer and add the section to `skills/load-balancer/SKILL.md`
- [x] Run `tests/check-structure.sh`
