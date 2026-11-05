# ai-skill

Agent skills by [gusdecool](https://github.com/gusdecool) that work in Claude Code, Codex and other agents
that read the shared skills folder.

## Skills

| Skill | Use case | Details |
|---|---|---|
| `/gusdecool:board-worker` | Work one board ticket end to end: PR, CI, merge, UAT watch, card to QA | [SKILL.md][board-worker] |
| `/gusdecool:load-balancer` | Spread tasks across AI providers by quota | [SKILL.md][load-balancer] |
| `/gusdecool:mysql-branch` | MySQL branching: one database per git branch / worktree | [SKILL.md][mysql-branch] |

In Claude Code the skill is `/gusdecool:<name>`. In other agents, say its name, for example "use MySQL branch".

[board-worker]: skills/board-worker/SKILL.md
[load-balancer]: skills/load-balancer/SKILL.md
[mysql-branch]: skills/mysql-branch/SKILL.md

## Install

You need Docker (for the MySQL your apps use) and git. Pick one way.

### Option A: any agent (Claude Code, Codex and others)

```
npx skills add gusdecool/ai-skill
```

The `skills` tool asks which skills and which agents to install for. Choose the skills you want. It lands in
`~/.agents/skills/`, which Codex and other agents read, and it is linked into `~/.claude/skills/` for Claude Code.

### Option B: Claude Code plugin

Inside Claude Code:

```
/plugin marketplace add gusdecool/ai-skill
/plugin install gusdecool@gusdecool
```

Plugin skills are namespaced, so the command becomes `/gusdecool:mysql-branch`. Every skill added to this repo later
shows up as `/gusdecool:<skill-name>`.

### Option C: Codex plugin

```
codex plugin marketplace add gusdecool/ai-skill
codex plugin add gusdecool
```

### Check it works

Restart or open a new agent session and ask: "what skills do you have?" You should see `mysql-branch`.
To update later, run `npx skills update` (Option A),
`/plugin marketplace update gusdecool` (Option B)
or `codex plugin marketplace upgrade` (Option C).

## mysql-branch

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
bash tests/mysql-branch.test.sh
```

The integration tests start a throwaway `mysql:8.0` container and remove it at the end. Docker is required.
CI runs the same checks plus `shellcheck`.

## License

[MIT](LICENSE). Keep the copyright notice when you copy or modify the code.

## UAT section convention

The `board-worker` skill reads each repo's README to learn how its UAT works. Add a `## UAT` section whose first line
is one of these forms:

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
