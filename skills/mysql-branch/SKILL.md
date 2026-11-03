---
name: mysql-branch
description: Use when the user says "use MySQL branch" or wants a separate MySQL database per git branch or worktree, so feature work does not touch the shared local dev database. Creates, switches, lists and drops branch databases cloned from a template, for MySQL running in Docker.
---

# MySQL branch

MySQL has no built-in branching, so each branch gets a full copy of a template database, named `<app>_<branch>`.
The bundled script does the work; you run it and report the result.

Script: `scripts/mysql-branch.sh`, relative to this skill's folder. Run it from inside the user's repo.

## One-time setup per repo

Create `.mysql-branch` in the repo root (ask the user for any value you cannot find in the repo's env files):

```
app=myapp                # prefix for branch databases, [A-Za-z0-9_]
source=myapp_dev         # existing local database the template is copied from
env_file=.env.local      # file that holds the connection setting
env_var=DATABASE_URL     # variable to rewrite; a URL keeps everything but the database name
```

Add `.mysql-branch` to the repo only if the team shares the same names; otherwise add it to `.git/info/exclude`.
The env variable must already exist in the env file.

Then build the template once: `scripts/mysql-branch.sh template` (add `--schema-only` for no data).

## When the user says "use MySQL branch"

1. Check `.mysql-branch` exists; if not, do the setup above first.
2. Check the template exists via `list`; if not, run `template`.
3. Run `scripts/mysql-branch.sh create` (uses the current git branch; pass a name to override).
   This clones the template and points the env variable at the new database.
4. Tell the user the database name and that the env file changed.

| Command | Use |
|---|---|
| `template [--schema-only]` | Rebuild the template from `source`. Run again to refresh it. |
| `create [branch] [--schema-only]` | New branch database, then `use`. |
| `use [branch]` | Point the env file at an existing branch database. |
| `name [branch]` | Print the database name. |
| `list` | Show template, active and stale databases. |
| `drop [branch] --yes` | Remove a branch database. |

## Rules

- Never run `drop --yes` without the user confirming that exact database in this conversation. Without `--yes`
  the script only reports what it would drop.
- The script only drops databases it created (it keeps a registry); do not drop databases with raw SQL.
- Do not touch the source database or any live server. Everything runs against the local Docker MySQL.
- Stale databases (git branch gone) are suggestions for the user, never cleaned up automatically.

## Connection

Defaults: Docker container `mysql`, user `root`, password read from the container's `MYSQL_ROOT_PASSWORD`.
Override with `MYSQL_BRANCH_CONTAINER`, `MYSQL_BRANCH_USER`, `MYSQL_BRANCH_PASSWORD`.

## Limits

Branches are full copies, slow for big data. Views or routines that hardcode the source database name still point
at it. A branch that exists only on the remote shows as stale.
