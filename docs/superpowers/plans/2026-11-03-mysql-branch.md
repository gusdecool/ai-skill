# mysql-branch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** A public, installable skill that gives each git branch its own MySQL database cloned from a template.

**Architecture:** One bash script (`docker exec` to the MySQL container) with a registry table for safety, a
`SKILL.md` that tells agents when and how to call it, and plugin manifests so Claude Code gets `/gusdecool:mysql-branch`.

**Tech Stack:** bash, awk, Docker, MySQL 8.0, Claude Code plugin manifests.

**Spec:** `docs/superpowers/specs/2026-11-03-mysql-branch-design.md`

## Global Constraints
- Lines at most 120 characters. Every function has a one-line doc comment.
- Script depends only on bash, docker, awk, sed, git, shasum.
- Never drop a database that is not in `mysql_branch_meta.branches`.
- Tests use a throwaway `mysql:8.0` container, never the user's own MySQL.

## Review Focus
- Branch name with slashes, uppercase, spaces or quotes maps to a valid identifier.
- Branch name over 64 characters maps to a stable, unique-enough name.
- `create` twice for the same branch fails without touching data.
- `drop` of an unregistered or template database is refused.
- `use` on a URL value keeps host, port, credentials and query string.

---

### Task 1: Script core (template, create, name, use)

**Files:**
- Create: `skills/mysql-branch/scripts/mysql-branch.sh`
- Test: `tests/mysql-branch.test.sh`

**Produces:** `mysql-branch.sh template|create|name|use` as in the spec.

- [x] **Step 1: Write the failing test script** covering template copy, create isolation, `--schema-only`, long-name
  hashing, duplicate create failing, `use` on a URL value and on a quoted plain value, template refusing to overwrite
  an unregistered database.
- [x] **Step 2: Run it and see it fail** (`bash tests/mysql-branch.test.sh`; script missing).
- [x] **Step 3: Implement the script** with the container wrapper, config parser, slug, registry, and the four commands.
- [x] **Step 4: Run the tests and see them pass.**
- [x] **Step 5: Commit.**

### Task 2: list and drop

**Files:**
- Modify: `skills/mysql-branch/scripts/mysql-branch.sh`
- Modify: `tests/mysql-branch.test.sh`

- [x] **Step 1: Add failing tests:** `list` marks active and stale; `drop` without `--yes` keeps the database;
  `drop --yes` removes it; `drop` of an unregistered database and of the template is refused.
- [x] **Step 2: Implement `list` and `drop`.**
- [x] **Step 3: Run all tests and see them pass.**
- [x] **Step 4: Commit.**

### Task 3: Skill, plugin manifests, README

**Files:**
- Create: `skills/mysql-branch/SKILL.md`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `README.md`

- [x] **Step 1: Write `SKILL.md`** with trigger description ("use MySQL branch"), the `.mysql-branch` format, the
  command flow, and the rule that the agent confirms with the user before `drop --yes`.
- [x] **Step 2: Write the plugin and marketplace manifests** (plugin name `gusdecool`), validate with
  `claude plugin validate .` if available.
- [x] **Step 3: Write `README.md`** with both install paths, quickstart, limits.
- [x] **Step 4: Commit, push, open the PR, watch CI if any.**
