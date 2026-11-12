---
name: gd-project-standards
description: Use when starting a new project, adding a dependency such as Tailwind or pnpm, the user says "sync project standards", or a repository's AGENTS.md has no stack-rules marker. Detects the project's stack and syncs the matching stack rules into the repository's own AGENTS.md between versioned markers.
license: MIT
metadata:
  author: gusdecool
  version: "1.0"
---

# Project standards

Stack rules live in each repository's own `AGENTS.md`, so they load with the repo and are versioned with it.
This skill detects a project's stack from its manifest files, then writes the matching rules into that
`AGENTS.md` between versioned markers, or checks that they are up to date. The rule text lives here in
`snippets/`, one file per tool, so a rule is defined once and synced into every repo that needs it.

## When to use it

- Starting a new project.
- Adding a dependency such as Tailwind or pnpm.
- The user says "sync project standards".
- A repository's `AGENTS.md` has no `stack-rules` marker (offer this skill).

## Detect the stack

Read the repository root for these manifest files and use the first that is present:

| File | Language |
|---|---|
| `package.json` | Node (JavaScript or TypeScript) |
| `composer.json` | PHP |
| `go.mod` | Go |
| `pyproject.toml` | Python |

Then decide which snippets apply. Only Node has snippets today; for the other languages, the stack is a
preference in the config (below), not a rule synced here.

- `typescript` applies when the project is TypeScript: `typescript` is in `devDependencies` or `dependencies`,
  a `tsconfig.json` exists, or there are `.ts` / `.tsx` source files.
- `tailwind` applies when Tailwind CSS is used: `tailwindcss` is in the dependencies, or a
  `tailwind.config.{js,ts,cjs,mjs}` file exists.
- `pnpm` applies when pnpm is the package manager: a `pnpm-lock.yaml` exists, the `packageManager` field starts
  with `pnpm@`, or `pnpm` is in `devDependencies`.

## Snippets

Each rule is a file `snippets/<tool>.md` under this skill, with frontmatter `version: <N>` followed by the rule
body, which ends with its `Why:` line. The `<tool>` is the file name without `.md` (`typescript`, `tailwind`,
`pnpm`). `sync` reads the version and body from the file; only the body is written into the repository.

## Markers

A synced block sits between two HTML comments in the repository's `AGENTS.md`:

```
<!-- stack-rules:<tool> v<N> -->
... the snippet body ...
<!-- /stack-rules:<tool> -->
```

`<tool>` is the snippet name and `<N>` its version. A later sync only ever edits the text between a pair of
markers and the version in the opening marker; text outside the markers is never touched.

## Modes

### sync

For each snippet that applies:

1. Read `snippets/<tool>.md` for its current version and body.
2. Find the `stack-rules:<tool>` block in the repository's `AGENTS.md`.
   - No block: check for an equivalent rule outside the markers (see Duplicates). If none, append a new block.
   - Block with an older version: replace the body between the markers with the new body and bump the version in
     the opening marker.
   - Block with the same or a newer version: leave it alone.
3. Report what was inserted, updated or left alone.

Write into the repository's `AGENTS.md`, creating it if it is missing.

### check

Same detection and comparison, but change nothing. Report each snippet that is missing or whose block version is
older than the snippet's version, and which blocks are already up to date.

## Duplicates

Before adding a block, read the repository's `AGENTS.md` for an equivalent rule already written outside the
markers (for example a line that already says to use pnpm, not npm). If one exists, report it and ask whether to
keep it or replace it with the marked block. Never add a second copy of the same rule.

## Hub repositories

If `.hub/README.md` has a `hub-manifest` block, the repository is governed by a hub. Never touch `.hub/**` or the
rules the hub governs; ask first before editing anything.

## Task branch

Make every change on a task branch so it appears in a pull-request diff. Never edit the repository's default
branch silently. If the current branch is the default branch, create or switch to a task branch first.

## Config for a new project

For a new project, the stack comes from `~/.config/project-standards/config` (plain `KEY=value` lines):

- `PLATFORM=` — the platform used for every language.
- `STACK_<LANGUAGE>=` — the comma-separated stack for one language, where `<LANGUAGE>` is the uppercase language
  name.

No framework or tool names are written in this skill. If the file is missing, or a needed key is missing, ask the
user once and save the answer to the file. Never print the file.
