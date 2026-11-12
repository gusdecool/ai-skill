# Model policy owns the tier table, the rules and the model lookup

Date: 2026-11-12. Status: approved by the owner on 2026-11-12.

## Why

Model tiering is spread over two repos and five places today:

| Place | Holds |
|---|---|
| `agent-standards/global/models.md` | tier table, tier rules, launch ids |
| `gusdecool-model-policy/SKILL.md` | the tier rules again, phase tiers, subagent dispatch |
| `gusdecool-load-balancer/SKILL.md` | the tier rules a third time |
| `gusdecool-board-worker/scripts/pick-provider` | its own table parser and hardcoded Mid launch ids |
| `~/.claude/agents/sdd-*.md` | Claude model per subagent role, in no repo |

Two things go wrong because of it. A rule changed in one copy leaves the others stale. And nothing stops a dispatch
that skipped the skill: a Claude subagent with no model inherits the session's model, so a session on an Ultra model
runs its subagents on Ultra.

## Goals

- One owner. `gusdecool-model-policy` holds the tier table, the tier rules and the launch ids. Other skills point to it.
- The model for a worker comes from a script, not from the agent copying an id out of a table.
- A Claude subagent cannot silently inherit a High or Ultra session model.
- The provider-neutral part and the Claude-only part are kept apart, so another tool can get its own adapter later.

## Non-goals

- A Codex, Antigravity or OpenCode adapter. It is added when one of them becomes the main orchestrator.
- Merging the two `pick-provider` scripts into one.
- Changing the quota formula, the cutoffs or the phase-tier table.
- Shipping the Claude adapter through the Claude Code plugin format.

## Layout

```
skills/gusdecool-model-policy/
  SKILL.md                       rules (the only copy), phase tiers, how each tool pins a model
  models.md                      tier table, tier definitions, provider map, launch ids
  scripts/
    resolve-model                provider + tier -> launch id
    install-claude-adapter       links the agents and registers the hook
  adapters/
    claude/
      agents/sdd-*.md            the four agent definitions, moved from ~/.claude/agents
      hooks/guard-subagent-model PreToolUse guard for subagent dispatch
```

## `models.md`

Moved from `agent-standards/global/models.md`. Changes:

- The "Rules" section is removed; the rules live in `SKILL.md` only.
- The tier table and "Tier definitions" stay as they are (the weekly model watch parses the tier table).
- New "Providers" table, so scripts stop hardcoding the mapping:

  | Quota provider | Agent CLI | Table rows |
  |---|---|---|
  | claude | claude | Claude |
  | codex | codex | Codex |
  | antigravity | agy | Gemini |
  | opencodeGo | opencode | DeepSeek, Kimi |

- "Launch IDs" becomes strict so a script can read it: one model per row, columns `Provider | Model | Launch id`,
  where Provider and Model are written exactly as in the tier table and the id is one value or `none`. The notes now
  in the cells (reasoning-level variants, "unverified") move to prose under the table.
- "API model IDs" stays as is.

## `resolve-model`

```
resolve-model --provider <claude|codex|antigravity|opencodeGo> --tier <Low|Mid|High|Ultra> [--allow-high]
```

- Reads `models.md` next to the skill (`MODELS_FILE` overrides it, for tests).
- Takes the provider's table rows in the order of the "Providers" table, and the model names in each tier cell in the
  order written. The first model that has a launch id other than `none` wins. A `(proposed)` model is skipped.
- Prints `{"provider","agent","tier","model","launchId"}`.
- Exit codes: 0 found; 1 the provider has no usable model in that tier; 2 bad arguments or unreadable table;
  3 High or Ultra asked without `--allow-high`. The caller passes `--allow-high` only after the user's OK in the
  conversation.

## Load balancer

- `scripts/pick-provider` gains `--tier <tier>` and `--allow-high`. With `--tier` it calls `resolve-model` for every
  provider, leaves out those with no model in the tier, and adds `tier`, `agent` and `model` (the launch id) for the
  chosen provider to its JSON. Without `--tier` it behaves as today.
- `SKILL.md`: step 1 becomes "load `gusdecool-model-policy`"; the restated tier rules are removed. "Choosing the
  provider" tells the agent to always pass `--tier` and to use the printed `model`. New step: when the chosen provider
  is the agent's own, dispatch a subagent the way model-policy says; otherwise launch a worker with that `model`.

## Board worker

- `scripts/pick-provider` drops its table parser, the Codex cache lookup and the hardcoded ids. It calls the load
  balancer's script with `--reserved claude --tier <tier>` and prints the same `{provider, model, tier}` as today.
  It never passes `--allow-high`, so High and Ultra still exit 2.
- `SKILL.md`: the model comes from the script's output.

## Model policy `SKILL.md`

- Points to `models.md` next to it instead of the file named by the global `AGENTS.md`.
- Holds the only copy of the tier rules.
- "Dispatching": one neutral rule (pin the tier's model explicitly, with the tool's own mechanism), then one short
  bullet per tool. Claude: the `sdd-*` agents, or `model` set to `haiku` or `sonnet`. Workers: `pick-provider --tier`.

## Claude adapter

**Agents.** The four `sdd-*.md` files are copied in unchanged.

**Hook.** `guard-subagent-model` runs before every subagent dispatch (tool `Agent`, or `Task` in older versions):

| Dispatch | Result |
|---|---|
| `model` is `haiku` or `sonnet` | allowed |
| no `model`, and the agent's definition pins `haiku` or `sonnet` | allowed |
| no `model`, and no definition pins one | refused: "would inherit the session's model; load `gusdecool-model-policy`" |
| effective model is `opus`, `fable` or anything else; or the agent type is `fork` | the user is asked to confirm |

The agent definition is looked up in the project's `.claude/agents/` and then `~/.claude/agents/`.

**Install.** `install-claude-adapter` links the four agent files into `~/.claude/agents/` and adds the hook to
`~/.claude/settings.json`. It is safe to run twice, keeps a backup of the settings file, refuses to replace an agent
file that is not its own link unless `--force` is given, and has `--uninstall`. It is run once by hand after
`npx skills update -g`; the links then follow later updates.

## `agent-standards` (second pull request, after this one is merged and installed)

- `global/models.md`, `global/models.sources.json`, `scripts/model-watch.ts`, its test, the `model-watch` package
  script and `.github/workflows/model-watch.yml` are deleted; the README section about the watch goes with them.
- `global/AGENTS.md`: the "Model tiers" pointer in section 7 is removed. Section 6 keeps "Mid tier is the default"
  and section 8 keeps the trigger row.

## Weekly model watch (moves into this repo)

The job needs no AI agent: it reads each provider's pricing page with patterns and opens one PR with new models
marked `(proposed)`. It moves as it is:

```
tools/model-watch/
  model-watch.ts            unchanged logic; edits skills/gusdecool-model-policy/models.md
  model-watch.test.ts
  models.sources.json
package.json, pnpm-lock.yaml   repo root; scripts `test` and `model-watch`
.github/workflows/model-watch.yml
```

- It lives outside `skills/` so it is not installed on anyone's machine with the skill.
- CI gains a job that runs `pnpm test`.
- `tests/check-structure.sh` exempts `tools/model-watch/models.sources.json` from the 120 character limit, because
  a pattern inside a JSON string cannot be wrapped.
- This adds Node 24, pnpm and TypeScript to a repo that was shell-only. The owner accepted that.

## Tests

- New `tests/gusdecool-model-policy.test.sh`: `resolve-model` (each provider at Mid, `none`, a model with no launch
  id, a proposed model, High without and with the flag, bad arguments); the hook (each row of the table above); the
  installer against a temporary home (install, second run, uninstall, refusal to overwrite); and a check that the
  `sdd-*` model lines agree with the Claude row of `models.md`.
- `tests/gusdecool-load-balancer.test.sh`: `--tier` cases. `tests/gusdecool-board-worker.test.sh`: updated for the
  new source of the ids.
- The new test file is added to CI. The load balancer and board worker tests are not in CI today; that is left as is.

## Calls made by the author (not decided by the owner)

1. `resolve-model` reads only the table. The board worker's lookup of the newest Sol slug in the Codex cache goes
   away, so a renamed Codex slug fails the launch until `models.md` is updated. Reason: one source of ids.
2. Antigravity at Mid launches `gemini-3.8-flash-medium` (the id in the table, checked 2026-11-11) instead of the
   board worker's hardcoded `gemini-3.8-flash`.
3. The hook asks for confirmation on High and Ultra instead of refusing, so the user's OK is one keypress. In an
   unattended session an "ask" cannot be answered, which amounts to a refusal.
4. Built-in Claude agents with no model (for example `Explore`) are refused until the dispatch names `haiku` or
   `sonnet`.
5. `pick-provider --tier` stays optional in the script; the skill text makes it mandatory.
6. The adapter is installed by a script, not by the `skills` tool, because that tool does not write to
   `~/.claude/agents` or to the settings file.

## Decided by the owner

1. `models.md` moves into this public repo. It holds the owner's provider list and tier ratings and no secrets.
2. The weekly model watch moves into this repo with the table.
3. The hook is part of this change, and so is `resolve-model`.
4. A Codex adapter waits until Codex becomes the main orchestrator.
