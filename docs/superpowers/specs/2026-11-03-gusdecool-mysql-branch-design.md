# gusdecool-mysql-branch design

Per-git-branch MySQL databases for local development, cloned from a template database, so feature work never
touches the shared dev database. MySQL has no copy-on-write branching (unlike Neon), so a branch is a full copy.

## Decisions
- Public repo `gusdecool/ai-skill`, MIT. Works as a Claude Code plugin (`gusdecool-mysql-branch`) and as a
  plain skill installed with `npx skills add gusdecool/ai-skill` (Codex and other agents).
- Bash script talking to a MySQL running in Docker through `docker exec`. No other dependencies.
- Template database `<app>_template` is built from a local source database named in config. It never reads a live
  server.
- A branch gets schema plus data from the template. `--schema-only` copies the schema only.
- Each repo has a `.mysql-branch` file naming the app, the source database, and the env file and variable to rewrite.
- Cleanup is manual. `list` flags branch databases whose git branch no longer exists.
- Connection: container `mysql`, user `root`, overridable by `MYSQL_BRANCH_CONTAINER`, `MYSQL_BRANCH_USER`,
  `MYSQL_BRANCH_PASSWORD`. The default root password is read inside the container (`MYSQL_ROOT_PASSWORD`), so it
  never appears in the repo or on a command line.

## Interface
`mysql-branch.sh <command> [branch] [flags]`; `branch` defaults to the current git branch.

| Command | Behavior |
|---|---|
| `template [--schema-only]` | Rebuild `<app>_template` from `source`. Never overwrites a database it did not make. |
| `create [branch] [--schema-only]` | Clone the template into `<app>_<branch-slug>`, register it, then run `use`. |
| `use [branch]` | Rewrite `env_var` in `env_file` to point at the branch database. |
| `name [branch]` | Print the branch database name. |
| `list` | Show registered databases for the app: active, stale, or template. |
| `drop [branch] --yes` | Drop a registered branch database. Without `--yes` it only says what it would drop. |

## Naming
`<app>_<slug>`: branch lowercased, every non `[a-z0-9]` run replaced by `_`. Longer than 64 characters is cut to
57 plus `_` plus the first 6 hex of the branch's sha1. A branch whose slug is `template` is rejected.

## Safety
- A registry table `mysql_branch_meta.branches` records every database the tool creates. `drop` and `template`
  only ever drop registered databases.
- `use` fails if the env var is not already in the env file, instead of guessing.
- URL values (`scheme://user:pass@host:port/db?query`) keep everything but the database name; plain values are
  replaced whole, keeping their quotes.

## Limits
Full copies are slow for big data. Views or routines that hardcode the source database name still point at it.
Remote-only git branches show as stale.
