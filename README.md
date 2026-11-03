# ai-skill

Agent skills by [gusdecool](https://github.com/gusdecool) that work in Claude Code, Codex and other agents
that read the shared skills folder.

## Skills

### mysql-branch

A separate MySQL database for each git branch, so feature work stops touching your shared local dev database.
MySQL has no copy-on-write branching like Neon, so a branch is a full copy of a template database. It runs on
MySQL in Docker, which keeps your server version identical to production.

Tell your agent: **"use MySQL branch"**.

How it works:

1. `template` copies your local dev database into `<app>_template`.
2. `create` clones the template into `<app>_<branch>` and rewrites the database name in your env file.
3. `list` shows active and stale branch databases; `drop <branch> --yes` removes one.

Safety: the script records every database it creates and only ever drops those. It never connects to a live server.

Per-repo config, a `.mysql-branch` file in the repo root:

```
app=myapp
source=myapp_dev
env_file=.env.local
env_var=DATABASE_URL
```

Defaults: container `mysql`, user `root`, password read from the container's `MYSQL_ROOT_PASSWORD`.
Override with `MYSQL_BRANCH_CONTAINER`, `MYSQL_BRANCH_USER` and `MYSQL_BRANCH_PASSWORD`.

Limits: full copies are slow for big data; views or routines that hardcode the source database name still point at
it; remote-only git branches show as stale.

## Install

Claude Code, as a plugin (skills are namespaced, so this one is `/gusdecool:mysql-branch`):

```
/plugin marketplace add gusdecool/ai-skill
/plugin install gusdecool@gusdecool
```

Any agent (Claude Code, Codex and others), as a plain skill:

```
npx skills add gusdecool/ai-skill
```

Then say "use MySQL branch" (Claude plugin users can also run `/gusdecool:mysql-branch`).

## Development

```
bash tests/mysql-branch.test.sh
```

The tests start a throwaway `mysql:8.0` container and remove it at the end. Docker is required.

## License

[MIT](LICENSE). Keep the copyright notice when you copy or modify the code.
