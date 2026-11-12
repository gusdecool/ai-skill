# Model policy owns the tiers: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `gusdecool-model-policy` becomes the only owner of the tier table, the tier rules and the model lookup, with
a Claude adapter that stops a subagent from inheriting the session's model.

**Architecture:** `models.md` moves into the skill in a format a script can read. `resolve-model` turns a provider
and a tier into a launch id; both `pick-provider` scripts call it. The Claude-only parts (agent files, hook,
installer) sit under `adapters/claude/`. The weekly model watch moves in under `tools/model-watch/`.

**Tech Stack:** bash, jq, awk for skills and tests; Node 24 with built-in TypeScript and `node --test` for the model
watch; GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-12-model-policy-owns-tiers-design.md`

## Global Constraints

- Every line at most 120 characters, in scripts, tests, markdown and JSON (`tests/check-structure.sh` enforces it;
  `SKILL.md` files and `tools/model-watch/models.sources.json` are exempt).
- Commands have no file extension and are executable; sourced libraries end in `-lib.sh`.
- Every function, script and test helper gets a one or two line doc comment directly above it.
- Scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`; tests use `set -uo pipefail` and the `assert_eq`
  style of `tests/gusdecool-load-balancer.test.sh`.
- No skill text names a model. Model names live in `models.md` and in `adapters/claude/agents/*.md` only.
- Tests never call Orca or any network: use the stub `orca` and `MODELS_FILE` fixtures.
- Quota provider keys are exactly `claude`, `codex`, `antigravity`, `opencodeGo`. Tiers are exactly `Low`, `Mid`,
  `High`, `Ultra`.
- Tick each task's boxes in the same commit that finishes it. Branch: `gusdecool/Load-Balancer-Model-Tier`.

## Review Focus

- `models.md` unreadable or missing its tables: `resolve-model` exits 2 with a message, never prints an empty id.
- A tier cell whose first model has launch id `none` (Gemini Low today): the next model is tried, then exit 1.
- A hook payload with no `subagent_type` or with unknown fields: treated as an agent with no pinned model (refused),
  never a crash that lets the call through.
- `~/.claude/settings.json` missing, or holding other `PreToolUse` hooks (Orca's): the installer keeps every existing
  entry and adds exactly one of its own.
- `pick-provider --tier` when `resolve-model` exits 3 for every provider: exit 2 with the "needs the user's OK"
  message, not "all providers over cutoff".

---

### Task 1: `models.md` in the skill and `resolve-model` (judgment)

**Files:**
- Create: `skills/gusdecool-model-policy/models.md`
- Create: `skills/gusdecool-model-policy/scripts/resolve-model`
- Create: `tests/gusdecool-model-policy.test.sh`

**Interfaces:**
- Produces: `resolve-model --provider <key> --tier <tier> [--allow-high]`; stdout one JSON line
  `{"provider","agent","tier","model","launchId"}`; exit 0 found, 1 no usable model, 2 bad arguments or unreadable
  table, 3 High or Ultra without `--allow-high`. Env `MODELS_FILE` overrides the default `../models.md` relative to
  the script.

- [ ] **Step 1: Write `models.md`.** Copy `~/Developer/gusdecool/agent-standards/global/models.md`, then: delete the
  "Rules" section; keep the tier table, "Tier definitions" and "API model IDs" unchanged; add a "Providers" table
  with header `| Quota provider | Agent CLI | Table rows |` and rows `claude | claude | Claude`,
  `codex | codex | Codex`, `antigravity | agy | Gemini`, `opencodeGo | opencode | DeepSeek, Kimi`; rewrite
  "Launch IDs" as header `| Provider | Model | Launch id |`, one model per row, names exactly as in the tier table,
  id in backticks or the word `none`. Ids: Haiku 5.5 `claude-haiku-5-5`, Sonnet 5.5 `claude-sonnet-5-5`, Opus 5.5
  `claude-opus-5-5`, Fable 5.2 `claude-fable-5-2`, Mythos 5.2 `none`, Luna `gpt-6-luna`, Terra `gpt-6.1-terra`, Sol
  `gpt-6.1-sol`, Astra `gpt-6-astra`, 3.5 Flash-Lite `none`, 3.6 Flash `none`, 3.8 Flash `gemini-3.8-flash-medium`,
  Argon `none`, V4.1 Flash `opencode-go/deepseek-v4.1-flash`, V4 Pro `opencode-go/deepseek-v4-pro`, K2.6 `none`,
  K2.7 Code `opencode-go/kimi-k2.7-code`, K3.1-pro `opencode-go/kimi-k3.1-pro`, K3 `opencode-go/kimi-k3`. Move the
  cell notes (Mythos unverified, the `-low` / `-high` Gemini variants, the BM-56 reason, the two rules about reading
  ids from each CLI) to prose under the table.
- [ ] **Step 2: Write failing tests** in `tests/gusdecool-model-policy.test.sh` against a fixture table written by the
  test (not the real file), asserting:
  - `--provider claude --tier Mid` prints
    `{"provider":"claude","agent":"claude","tier":"Mid","model":"Sonnet 5.5","launchId":"claude-sonnet-5-5"}`, exit 0
  - `--provider codex --tier Low` gives `gpt-6-luna` (first name in the cell)
  - `--provider antigravity --tier Low` exits 1 (both models have id `none`)
  - `--provider opencodeGo --tier Mid` gives `opencode-go/deepseek-v4-pro` (first row of two), agent `opencode`
  - a fixture where DeepSeek Mid is `none` gives the Kimi id (second row is tried)
  - a cell `Sol (proposed), Terra` gives the Terra id (proposed is skipped)
  - `--provider codex --tier High` on a `none` cell exits 1 with `--allow-high`
  - `--provider claude --tier High` exits 3 without `--allow-high` and prints the Opus id with it
  - `--tier workhorse`, `--provider gemini`, a missing flag, and `MODELS_FILE=/nonexistent` each exit 2
  - a fixture with no "Launch IDs" table exits 2
  - the real `skills/gusdecool-model-policy/models.md` resolves Mid for all four providers (exit 0, non-empty id)
- [ ] **Step 3: Run** `bash tests/gusdecool-model-policy.test.sh`; expect failures (script missing).
- [ ] **Step 4: Implement `resolve-model`** with awk over the three tables. Strip backticks from ids. Check the tier
  gate (exit 3) before reading the table.
- [ ] **Step 5: Run** the test file and `bash tests/check-structure.sh`; expect both to pass.
- [ ] **Step 6: Commit** "Add the tier table and resolve-model to the model policy skill".

### Task 2: `pick-provider --tier` in the load balancer and the board worker (judgment)

**Files:**
- Modify: `skills/gusdecool-load-balancer/scripts/pick-provider`
- Modify: `skills/gusdecool-board-worker/scripts/pick-provider`
- Modify: `tests/gusdecool-load-balancer.test.sh`, `tests/gusdecool-board-worker.test.sh`

**Interfaces:**
- Consumes: `resolve-model` from Task 1 (path `../../gusdecool-model-policy/scripts/resolve-model` from each script,
  override with env `RESOLVE_MODEL`).
- Produces: load balancer `pick-provider --reserved <p> --tier <tier> [--allow-high]` adds top-level `tier`,
  `agent`, `model` (the launch id) for the chosen provider. Board worker `pick-provider [--tier T] [--orchestrator]`
  keeps printing `{"provider","model","tier"}` with `opencodeGo` shown as `opencode`.

- [ ] **Step 1: Write failing load balancer tests:** with a fixture `MODELS_FILE`, `--tier Mid` on the BM-55 quotas
  prints `chosen` `opencodeGo`, `model` `opencode-go/deepseek-v4-pro`, `agent` `opencode`, `tier` `Mid`; `--tier Low`
  shows `antigravity` skipped with reason `no Low model`; `--tier High` without `--allow-high` exits 2 and stderr
  says the tier needs the user's OK; no `--tier` leaves the output without `model` (old behavior); `--tier bogus`
  exits 2; with `--orchestrator` the tier is ignored.
- [ ] **Step 2: Run** `bash tests/gusdecool-load-balancer.test.sh`; expect the new cases to fail.
- [ ] **Step 3: Implement in the load balancer script.** Before scoring, run `resolve-model` per provider; exit 1
  adds the provider to the excluded set with reason `no <tier> model`; exit 3 from any provider stops with exit 2;
  exit 2 stops with exit 2. After scoring, merge the chosen provider's `agent` and `launchId` into the result.
  Update the usage header.
- [ ] **Step 4: Update the board worker tests:** antigravity's model is now `gemini-3.8-flash-medium`; the Codex
  model comes from the table (`gpt-6.1-sol`), so drop `CODEX_MODELS_CACHE` and the cache fixture; `--tier High`
  exits 2 both when the cell is `none` for every provider (still exit 1) and when a model exists (exit 2, needs OK);
  the stub `models.md` fixtures gain "Providers" and "Launch IDs" tables.
- [ ] **Step 5: Rewrite the board worker script** as a thin wrapper: parse `--tier` and `--orchestrator`, call the
  load balancer script with `--reserved claude --tier "$tier"` (plus `--orchestrator`), map its exits and print the
  same shapes as today, including `{"error":"no provider has a <tier> model"}` and
  `{"error":"all providers over cutoff","earliestResetsAt":...}`. With `--orchestrator` print the Mid model of
  claude. Remove `table_cell`, `codex_model` and the hardcoded ids. Default `MODELS_FILE` is the skill's file.
- [ ] **Step 6: Run** both test files and `bash tests/check-structure.sh`; expect all to pass.
- [ ] **Step 7: Commit** "Resolve the worker model from the tier in pick-provider".

### Task 3: Claude adapter: agents, hook and installer (judgment)

**Files:**
- Create: `skills/gusdecool-model-policy/adapters/claude/agents/sdd-implementer.md`, `sdd-implementer-sonnet.md`,
  `sdd-task-reviewer.md`, `sdd-final-reviewer.md` (copies of `~/.claude/agents/sdd-*.md`, unchanged)
- Create: `skills/gusdecool-model-policy/adapters/claude/hooks/guard-subagent-model`
- Create: `skills/gusdecool-model-policy/scripts/install-claude-adapter`
- Create: `tests/gusdecool-model-policy-claude.test.sh`
- Modify: `tests/check-structure.sh` (hooks under `adapters/*/hooks/` must be executable too)

**Interfaces:**
- Produces: `guard-subagent-model` reads the hook JSON on stdin (`tool_name`, `tool_input.subagent_type`,
  `tool_input.model`, `cwd`). Allowed: exit 0, no output. Otherwise exit 0 with
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"|"ask",
  "permissionDecisionReason":"..."}}`. Env `CLAUDE_AGENTS_DIR` overrides `~/.claude/agents` (tests).
- Produces: `install-claude-adapter [--uninstall] [--force]`; env `CLAUDE_HOME` overrides `~/.claude` (tests).

- [ ] **Step 1: Write failing hook tests,** one per row of the spec's table plus: tool `Bash` is allowed untouched;
  tool `Task` is treated like `Agent`; `subagent_type` missing with no model is denied; `sdd-implementer` with no
  model is allowed (definition pins `haiku`); `sdd-final-reviewer` asks; `model: opus` on `sdd-implementer` asks;
  `subagent_type: fork` asks even with `model: sonnet`; a project `.claude/agents/x.md` pinning `sonnet` under `cwd`
  is allowed; malformed stdin is denied. The deny reason contains `gusdecool-model-policy`.
- [ ] **Step 2: Write failing installer tests** against a temp `CLAUDE_HOME`: install creates four symlinks and one
  `PreToolUse` entry with matcher `Agent|Task` whose command is the guard's absolute path; an existing `PreToolUse`
  entry with matcher `*` survives; a second run adds nothing; a regular file at `agents/sdd-implementer.md` makes it
  exit 1 without `--force` and is replaced (after a `.bak` copy) with it; a missing `settings.json` is created;
  `settings.json.bak` holds the previous content; `--uninstall` removes only its own links and entry.
- [ ] **Step 3: Write the consistency test:** each `adapters/claude/agents/*.md` `model:` alias matches the Claude
  row of the real `models.md` (`haiku` in Low, `sonnet` in Mid, `opus` in High), compared case-insensitively on the
  first word of the model name.
- [ ] **Step 4: Run** `bash tests/gusdecool-model-policy-claude.test.sh`; expect failures.
- [ ] **Step 5: Implement the hook and the installer** (jq for all JSON). The hook reads the pinned model from the
  `model:` frontmatter line. `inherit` or an unknown alias counts as "anything else" (ask).
- [ ] **Step 6: Run** the test file and `bash tests/check-structure.sh`; expect both to pass.
- [ ] **Step 7: Commit** "Add the Claude adapter for the model policy".

### Task 4: Move the weekly model watch into this repo (mechanical)

**Files:**
- Create: `tools/model-watch/model-watch.ts`, `tools/model-watch/model-watch.test.ts`,
  `tools/model-watch/models.sources.json`, `package.json`, `pnpm-lock.yaml`, `.github/workflows/model-watch.yml`
- Modify: `.github/workflows/ci.yml`, `tests/check-structure.sh`, `.gitignore`

**Interfaces:**
- Consumes: `skills/gusdecool-model-policy/models.md` from Task 1 (tier table header unchanged).

- [ ] **Step 1: Copy** the three files from `~/Developer/gusdecool/agent-standards` (`scripts/model-watch.ts`,
  `scripts/model-watch.test.ts`, `global/models.sources.json`). Change only paths: the models file is
  `../../skills/gusdecool-model-policy/models.md`, the sources file sits next to the script.
- [ ] **Step 2: Add `package.json`** (name `ai-skill`, private, `"type": "module"`, `packageManager` and `engines`
  as in `agent-standards`, scripts `test`: `node --test "tools/model-watch/*.test.ts"` and `model-watch`:
  `node tools/model-watch/model-watch.ts`), run `pnpm install` to write the lockfile, add `node_modules` to
  `.gitignore`.
- [ ] **Step 3: Run** `pnpm test`; expect every test to pass, including the round trip of the real `models.md`.
- [ ] **Step 4: Copy the workflow,** replacing `global/models.md` with `skills/gusdecool-model-policy/models.md`
  everywhere. Add a `model-watch` job to `ci.yml` (checkout, pnpm setup, Node 24, `pnpm install --frozen-lockfile`,
  `pnpm test`) and add the two new shell test files to the `checks` job.
- [ ] **Step 5: Exempt** `tools/model-watch/models.sources.json` from the line limit in `tests/check-structure.sh`,
  with the reason in a comment. Run it; expect a pass.
- [ ] **Step 6: Commit** "Move the weekly model watch next to the tier table".

### Task 5: Skill text and README (judgment)

**Files:**
- Modify: `skills/gusdecool-model-policy/SKILL.md`, `skills/gusdecool-load-balancer/SKILL.md`,
  `skills/gusdecool-board-worker/SKILL.md`, `README.md`, `tests/check-structure.sh`

**Interfaces:**
- Consumes: the flags and outputs of Tasks 1 to 3.

- [ ] **Step 1: Add failing structure checks:** the load balancer `SKILL.md` contains `gusdecool-model-policy` and
  `--tier`, and no longer contains `AGENTS.md` tier wording (`grep -c 'tier table'` is 0); the model policy
  `SKILL.md` contains `resolve-model` and `install-claude-adapter`; no `SKILL.md` contains `agent-standards`.
- [ ] **Step 2: Model policy.** "Read the tier table" points to `models.md` next to the skill. Keep "Tier rules" as
  the only copy. Replace "Dispatching subagents" with: the neutral rule (pin the tier's model explicitly with the
  tool's own mechanism; a dispatch with no model inherits the session's model); Claude (the `sdd-*` agents or
  `model` `haiku` / `sonnet`; the hook refuses anything else; install with `scripts/install-claude-adapter`); other
  tools (their own setting, model from `resolve-model`); workers (`pick-provider --tier`, never an id typed by hand).
- [ ] **Step 3: Load balancer.** "Before you start" step 1 becomes: load `gusdecool-model-policy`; tiers, rules and
  effort are there; keep the sentence about a repo `AGENTS.md` overriding tier values only with the user's yes.
  "Choosing the provider": always pass `--tier`; use the printed `model`; describe `--allow-high`. Add: when
  `chosen` is your own provider, dispatch a subagent as model-policy says; otherwise launch a worker with `--model`
  set to the printed `model`. "Dispatching": drop the bullets that restate tier rules or tell the agent to read ids
  from a table; keep the BM-56 launch-error bullet, pointing at the skill's `models.md`. Orca adapter: the two
  bullets on Codex and OpenCode slugs point to `pick-provider --tier`.
- [ ] **Step 4: Board worker.** Line 144: the model is the `model` field of `pick-provider`.
- [ ] **Step 5: README.** Add a `gusdecool-model-policy` section: what it owns, `resolve-model` usage, the Claude
  adapter install command (`~/.agents/skills/gusdecool-model-policy/scripts/install-claude-adapter`) and what it
  changes, the weekly model watch (text from the `agent-standards` README, paths updated). Add the two new test
  files and `pnpm test` to "Development".
- [ ] **Step 6: Run** `bash tests/check-structure.sh` and all four shell test files; expect passes.
- [ ] **Step 7: Commit** "Point the load balancer and board worker at the model policy".

### Task 6: Pull request for this repo

- [ ] **Step 1:** Run `shellcheck` on the new scripts and tests, every test file, and `pnpm test`.
- [ ] **Step 2:** `grep -c '\- \[ \]'` on this plan; only Tasks 6 and 7 may have open boxes.
- [ ] **Step 3:** Push and open the PR; watch CI until green. Do not merge.

### Task 7: `agent-standards` pull request (after the owner merges and installs Task 6)

Separate repository, separate worktree created through Orca (its main checkout backs the live `~/.claude/CLAUDE.md`
symlink, so it must not change branch).

- [ ] **Step 1:** Delete `global/models.md`, `global/models.sources.json`, `scripts/model-watch.ts`,
  `scripts/model-watch.test.ts`, `.github/workflows/model-watch.yml`; remove the `model-watch` package script and the
  README section "Weekly model watch".
- [ ] **Step 2:** `global/AGENTS.md` section 7: remove the "Model tiers" bullet. Leave sections 6 and 8 as they are.
- [ ] **Step 3:** Run `pnpm test`; open the PR. Do not merge.
- [ ] **Step 4:** After both merges: `npx skills update -g`, run `install-claude-adapter`, `git pull` in the
  standards clone.
