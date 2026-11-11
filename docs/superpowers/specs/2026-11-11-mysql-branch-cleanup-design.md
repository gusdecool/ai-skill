# mysql-branch cleanup step

Source: https://bungamata.atlassian.net/browse/BM-158

## Goal

The gusdecool-mysql-branch skill tells the AI to drop the branch databases it created once the PR is merged or the
task is done or abandoned, instead of leaving them behind.

## Acceptance criteria

- SKILL.md has a cleanup step: the AI lists the branch databases it created in this task and drops them with
  `drop <branch> --yes`.
- Safety: the AI names the exact databases and drops only ones it created in this task (the script registry). It
  never drops the template, the source, or a database another branch or session uses.
- A standing "use MySQL branch" instruction counts as consent to drop at the end. Otherwise the AI asks once,
  naming the databases.
- Test databases made by hand are replaced by script-made ones (`create <name>`), so the registry covers them.
- A BOARD-WORKER run drops its branch databases after the merge and before reporting done.

## Verify

Read SKILL.md: the cleanup step, the consent rule and the registry rule are present.
