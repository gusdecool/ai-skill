# ai-skill

Agent skills by [gusdecool](https://github.com/gusdecool) that work in Claude Code, Codex and other agents
that read the shared skills folder.

## Skills

| Skill | Use case | Details |
|---|---|---|
| `gd-orchestrate-ticket` | Orchestrate a ticket across repos with Orca workers | [SKILL.md][gd-orchestrate-ticket] |
| `gd-authoring-skills` | Change a skill by PR in its repo, install | [SKILL.md][gd-authoring-skills] |
| `gd-board-issue` | Write a board-ready issue (final spec, Auto merge) | [SKILL.md][gd-board-issue] |
| `gd-board-worker` | Work a board ticket: PR, CI, merge, UAT, card to QA | [SKILL.md][gd-board-worker] |
| `gd-git-workflow` | Git rules: branches, commits, PRs, CI, project board | [SKILL.md][gd-git-workflow] |
| `gd-infra-conventions` | IaC, CI pinning, migrations, deploy logs | [SKILL.md][gd-infra-conventions] |
| `gd-load-balancer` | Spread tasks across AI providers by quota | [SKILL.md][gd-load-balancer] |
| `gd-long-task-communication` | Estimate, follow-ups, at limit | [SKILL.md][gd-long-task-communication] |
| `gd-model-policy` | Model tier per phase of agent work | [SKILL.md][gd-model-policy] |
| `gd-mysql-branch` | MySQL branching: one database per git branch | [SKILL.md][gd-mysql-branch] |
| `gd-project-standards` | Sync stack rules into repo AGENTS.md | [SKILL.md][gd-project-standards] |
| `gd-rest-api-design` | REST URL, contract, error rules; design first | [SKILL.md][gd-rest-api-design] |

Every agent calls a skill by its name, for example `gd-mysql-branch`. Installed with `npx skills add`, the name is
the same in every agent. A Claude Code plugin adds its own prefix (see Install).

[gd-orchestrate-ticket]: skills/gd-orchestrate-ticket/SKILL.md
[gd-authoring-skills]: skills/gd-authoring-skills/SKILL.md
[gd-board-issue]: skills/gd-board-issue/SKILL.md
[gd-board-worker]: skills/gd-board-worker/SKILL.md
[gd-git-workflow]: skills/gd-git-workflow/SKILL.md
[gd-infra-conventions]: skills/gd-infra-conventions/SKILL.md
[gd-load-balancer]: skills/gd-load-balancer/SKILL.md
[gd-long-task-communication]: skills/gd-long-task-communication/SKILL.md
[gd-model-policy]: skills/gd-model-policy/SKILL.md
[gd-mysql-branch]: skills/gd-mysql-branch/SKILL.md
[gd-project-standards]: skills/gd-project-standards/SKILL.md
[gd-rest-api-design]: skills/gd-rest-api-design/SKILL.md

## Config files

Two skills read owner-specific values from a config file on your machine. Both use plain `KEY=value` lines, ask once
for a missing value and save the answer, and never print the file.

- `~/.config/git-workflow/config`: `BOARD_OWNER` (owner of the GitHub Project), `BOARD_NUMBER` (project number),
  `BOARD_REPO_OWNERS` (comma list of repo owners the board rules apply to), `BOARD_STATUS_BACKLOG`,
  `BOARD_STATUS_IN_PROGRESS` and `BOARD_STATUS_QA` (board columns). Without the file, or for a repo owner not in
  `BOARD_REPO_OWNERS`, `git-workflow` skips every board step and says so in one line.
- `~/.config/project-standards/config`: `PLATFORM=` and `STACK_<LANGUAGE>=` lines hold the stack preferences for a new
  project. Without the file, `project-standards` asks the user.

## Board worker config

`gd-board-worker` names no organization. On first use it asks for the owner of your GitHub Project, the project
number and the repo owners it may merge in, and saves them in `~/.config/board-worker/config` (run
`~/.agents/skills/gd-board-worker/scripts/board-setup` to create or change it). The scheduled dispatcher never
creates it: without the file its precheck skips the run with one line.

## Merge gate and flags

The worker merges its own PR only when `board-merge-gate` exits 0. A script checks all of this, so issue text cannot
talk past it:

- the issue says `Auto merge: true` and its author is an owner, member or collaborator of the repo;
- the repo owner is allowed and its visibility is not in `BOARD_BLOCKED_VISIBILITIES` (default `public`: a card in a
  public repo is ignored with a comment and moved to the HITL column);
- the PR changes no CI/CD file (workflows, pipelines, deploy scripts): those always need a human;
- the PR changes no infrastructure file (Terraform, Dockerfiles, Kubernetes, and so on) unless the config sets
  `BOARD_ALLOW_INFRA_CHANGE=true` (default `false`).

Otherwise the worker finishes the PR, leaves it open, comments the reasons and moves the card to the HITL
column. Extra path patterns for your own layout go in `BOARD_EXTRA_CICD_PATHS` and
`BOARD_EXTRA_INFRA_PATHS`.
All flags live in `~/.config/board-worker/config`, which the worker must never edit.

## UAT section convention

The `gd-board-worker` skill reads each repo's README to learn how its UAT works. Add a `## UAT` section whose
first line is one of these forms:

```
## UAT

UAT: <branch> | <deploy workflow file> | <url>
```

`<branch>` is the branch the PR targets, so merging it triggers the deploy (a repo that promotes `main` to a `uat`
branch writes `main`). `<deploy workflow file>` is the workflow under `.github/workflows/` that deploys it.

```
## UAT

UAT: none
```

For a repo with no UAT server. If the section is missing, the worker treats the repo as having no UAT and its PR adds:

```
## UAT

UAT: unknown
Please fill in this section: replace the line above with the UAT line for this repo.
```

The board scripts read at most 500 items from the project board (a known limit).

## Install

Install with the Vercel skills CLI. It copies the skills into Claude Code, Codex, Antigravity and OpenCode:

    npx skills add gusdecool/ai-skill

This is the recommended way. A Claude Code plugin also exists, but it adds its own prefix (/<plugin>:gd-load-balancer)
and the other three agents cannot read a Claude plugin.

Skill names start with gd- to avoid clashing with skills from other providers. Check what is already installed with
npx skills list before adding a skill from someone else.

The `skills` tool asks which skills and which agents to install for. It lands in `~/.agents/skills/`, which Codex
and other agents read, and it is linked into `~/.claude/skills/` for Claude Code. You also need Docker (for the
MySQL your apps use) and git.

### Claude Code plugin (optional)

Inside Claude Code:

```
/plugin marketplace add gusdecool/ai-skill
/plugin install gusdecool@gusdecool
```

Plugin skills are namespaced, so the command becomes `/gusdecool:gd-mysql-branch`.

### Codex plugin (optional)

```
codex plugin marketplace add gusdecool/ai-skill
codex plugin add gusdecool
```

### Check it works

Restart or open a new agent session and ask: "what skills do you have?" You should see `gd-mysql-branch`.
To update later, run `npx skills update`, `/plugin marketplace update gusdecool` (Claude plugin)
or `codex plugin marketplace upgrade` (Codex plugin).

## gd-model-policy

This skill owns the tier rules and phase tiers. Its `models.md` holds the tier table, provider map and launch ids.
The load balancer and board worker use this policy to select models.

Resolve a provider and tier to a launch id from the installed skill:

```sh
~/.agents/skills/gd-model-policy/scripts/resolve-model --provider codex --tier Mid
```

The JSON contains `provider`, `agent`, `tier`, `model` (the display name) and `launchId` (the launch value).
Exit codes are 0 for a match, 1 for no usable model, 2 for bad arguments or an unreadable table, and 3 for High or
Ultra without `--allow-high`. Use that flag only after the user approves the higher tier under the policy.
Why: higher cost needs explicit approval.

### Claude adapter

After installing or updating the skills with `npx skills update -g`, run once:

```sh
~/.agents/skills/gd-model-policy/scripts/install-claude-adapter
```

It links the four `sdd-*` agents into `~/.claude/agents/` and registers a subagent model hook in
`~/.claude/settings.json`. The hook prevents silent session model inheritance and asks for approval for other
models or forks. The installer backs up settings and is safe to run twice; the links follow later skill updates.
It refuses to replace an agent file it does not own unless given `--force`; `--uninstall` removes its links and hook.
Why: existing agent definitions must survive an install unless replacement is explicit.

### Weekly model watch

The job runs every Monday and on demand. It reads each provider's pricing page listed in
`tools/model-watch/models.sources.json`. It adds any model missing from
`skills/gd-model-policy/models.md` as `name (proposed)` in the tier the price guide suggests, through one PR
on the branch `bot/model-watch`. It never merges. If a page cannot be read, it opens a "Model watch failed" issue.
Why: proposed models need review before they can be selected for work.

Local run (Node 24 or newer):

```sh
pnpm install && pnpm run model-watch
```

Tests: `pnpm test`.

## gd-mysql-branch

### Why

You run MySQL in Docker, and every project connects to the same database. Start a feature branch, run a migration
or a seed script, and you have changed the data every other branch and project is using. Postgres users can use
Neon-style branching for this. MySQL has no equivalent.

The tempting fix is a hosted MySQL with branching, or a different engine. That breaks when your live server is
MySQL: your local database must behave exactly like production, so you want the same engine and the same version
(the Docker image).

So this skill keeps real MySQL and adds the branching around it:

- Each git branch gets its own database, cloned from a template.
- The branch's env file is pointed at that database for you, so nothing in your app changes.
- Experiments, failed migrations and test data stay in the branch. Drop it when you are done.

It is a full copy, not copy-on-write like Neon, so it suits databases up to a few GB. For very large data, use
`--schema-only` to copy just the structure.

### How to use it

**One-time setup per repo.** Create `.mysql-branch` in the repo root:

```
app=myapp                # prefix for branch databases
source=myapp_dev         # your existing local database, the template is copied from it
env_file=.env.local      # the file that holds your connection setting
env_var=DATABASE_URL     # the variable to rewrite (it must already exist in that file)
```

`env_var` can be a URL (`mysql://user:pass@127.0.0.1:3306/myapp_dev?serverVersion=8.0`, only the database name
changes) or a plain name (`DB_NAME=myapp_dev`).

**Day to day, just tell your agent:**

> use MySQL branch

The agent creates the template if it is missing, clones it for your current git branch and updates the env file.
You can also ask for the others in plain words: "list my MySQL branches", "drop the MySQL branch for
feat/login" (it asks you to confirm before dropping).

When the work ends (PR merged, task done or abandoned) the agent drops the branch databases it created in that task.
Saying "use MySQL branch" counts as consent to that; otherwise it asks once, naming the databases. It never drops the
template, the source or a database another branch uses. Test databases it needs are made with the script too, so the
same cleanup covers them.

**Or run the script yourself** (it lives in the skill's `scripts/` folder, run it from your repo):

| Command | What it does |
|---|---|
| `mysql-branch.sh template [--schema-only]` | Build or refresh `<app>_template` from `source`. |
| `mysql-branch.sh create [branch] [--schema-only]` | New database `<app>_<branch>`, then point the env file at it. |
| `mysql-branch.sh use [branch]` | Switch the env file to an existing branch database. |
| `mysql-branch.sh name [branch]` | Print the database name. |
| `mysql-branch.sh list` | Show the template and branch databases as active or stale. |
| `mysql-branch.sh drop [branch] --yes` | Remove a branch database. |

`branch` defaults to the current git branch. Stale means the git branch is gone: a hint to clean up, never done
automatically.

### Safety

- The script records every database it creates and only ever drops those. Your own databases are refused.
- It runs only against the local Docker MySQL and never connects to a live server.
- The template is built from your local `source` database, so refresh it (`template`) after you merge new
  migrations.

### Connection settings

Defaults: container `mysql`, user `root`, password read from the container's `MYSQL_ROOT_PASSWORD` (so it never sits
in your repo or on a command line). Override with `MYSQL_BRANCH_CONTAINER`, `MYSQL_BRANCH_USER` and
`MYSQL_BRANCH_PASSWORD`.

### Limits

Full copies are slow for big data. Views or routines that hardcode the source database name still point at it.
Branches that exist only on the remote show as stale.

## Development

```
bash tests/check-structure.sh
bash tests/gd-model-policy.test.sh
bash tests/gd-model-policy-claude.test.sh
bash tests/gd-load-balancer.test.sh
bash tests/gd-board-worker.test.sh
bash tests/gd-mysql-branch.test.sh
pnpm test
```

Node 24 or newer and pnpm are required for the model watch tests.
The MySQL integration tests start a throwaway `mysql:8.0` container and remove it at the end. Docker is required.
CI runs the same checks plus `shellcheck`.

## UAT

UAT: none

## License

[MIT](LICENSE). Keep the copyright notice when you copy or modify the code.
